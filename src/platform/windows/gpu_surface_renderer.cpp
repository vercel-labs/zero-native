#include "gpu_surface_renderer.h"

#include <d2d1.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dwrite_3.h>
#include <dxgi1_2.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace {

/* Compact binary gpu-surface packet decoding (wire format v5).
 *
 * This independent decoder deliberately repeats the encoder's tags and
 * bounds rather than sharing packed structs across the Zig/C++ ABI. A
 * version or layout disagreement is a refused present, which makes the
 * runtime resynchronize/fall back instead of drawing corrupt content. */
constexpr uint8_t kPacketVersion = 5;
constexpr size_t kRetainedCommandCap = 2048;
constexpr size_t kDirtyRectCap = kWindowsGpuDirtyRectCap;
constexpr uint32_t kMaxSurfacePixels = 8192;
/* Beyond this many combined damage rectangles (this paint's plus the
 * previous paint's), the per-rect clipped copies stop being cheaper than
 * one full-surface pass and the paint falls back to copying everything. */
constexpr size_t kSwapDirtyRectCap = 12;
constexpr float kBezierCircle = 0.5522847498307936f;

constexpr uint64_t canvasFontResourceId(uint64_t font_id) {
    /* Zero is DrawText's public default. It and the styled sans variants
     * resolve through the same bundled Geist regular resource the engine's
     * reference metrics use. */
    return font_id == 0 || (font_id >= 3 && font_id <= 6) ? 1 : font_id;
}

constexpr uint64_t canvasFallbackFontResourceId(uint64_t font_id) {
    return font_id == 2 ? 0 : 1;
}

constexpr float canvasStrokeWidth(float width) {
    return width > 0 ? width : 0;
}

static_assert(canvasFontResourceId(0) == 1, "default canvas text uses bundled Geist");
static_assert(canvasFontResourceId(2) == 2, "the built-in mono face keeps its resource id");
static_assert(canvasFontResourceId(6) == 1, "styled sans variants use bundled Geist");
static_assert(canvasFallbackFontResourceId(2) == 0, "mono keeps its platform fallback");
static_assert(canvasFallbackFontResourceId(64) == 1, "missing application fonts fall back to Geist");
static_assert(canvasStrokeWidth(-1.0f) == 0, "negative canvas strokes are empty");
static_assert(canvasStrokeWidth(0.0f) == 0, "zero-width canvas strokes are empty");
static_assert(canvasStrokeWidth(0.5f) == 0.5f, "subpixel canvas strokes keep their width");

template <typename T>
static void releaseCom(T *&value) {
    if (value) value->Release();
    value = nullptr;
}

static float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

/* True when `name` is set to anything other than "0" or the empty
 * string. Diagnostic switches only -- nothing behavioral reads this. */
static bool envFlagSet(const wchar_t *name) {
    wchar_t value[8] = {};
    const DWORD length = GetEnvironmentVariableW(name, value, static_cast<DWORD>(std::size(value)));
    if (length == 0) return false;
    if (length >= std::size(value)) return true; /* long value, definitely not "0" */
    return !(value[0] == L'\0' || (value[0] == L'0' && value[1] == L'\0'));
}

/* Small unsigned diagnostic knob; 0 when unset or unparseable. */
static unsigned envCount(const wchar_t *name) {
    wchar_t value[16] = {};
    const DWORD length = GetEnvironmentVariableW(name, value, static_cast<DWORD>(std::size(value)));
    if (length == 0 || length >= std::size(value)) return 0;
    unsigned parsed = 0;
    for (const wchar_t *cursor = value; *cursor; ++cursor) {
        if (*cursor < L'0' || *cursor > L'9') return 0;
        parsed = parsed * 10 + static_cast<unsigned>(*cursor - L'0');
    }
    return parsed;
}

static uint64_t gpuClockNs() {
    static LARGE_INTEGER frequency = [] {
        LARGE_INTEGER value = {};
        QueryPerformanceFrequency(&value);
        return value;
    }();
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    const uint64_t ticks_per_second = static_cast<uint64_t>(frequency.QuadPart);
    if (ticks_per_second == 0) return 0;
    const uint64_t ticks = static_cast<uint64_t>(counter.QuadPart);
    return (ticks / ticks_per_second) * 1000000000ULL +
        ((ticks % ticks_per_second) * 1000000000ULL) / ticks_per_second;
}

/* Env-gated presentation profiler.
 *
 * `NATIVE_SDK_GPU_PROFILE` names a log path; with it unset (every shipped
 * run) the file is opened once per process as null, `gpuProfileActive()` is
 * false, and each probe below costs one predicted branch and writes
 * nothing. It exists because the Direct2D path's real
 * costs are invisible from the outside: `ensureTargets` drops the whole
 * per-surface texture cache on any dimension change, and only an app that
 * actually holds textures pays for it. See `tools/gpu-image-fixture/`.
 *
 * Lines are key=value, one per event, in the shape the repo's automation
 * snapshots already use:
 *
 *   present seq=12 pw=1200 ph=800 rebuild=1 flushed=16 targets_us=170 \
 *           images_us=940 images_n=16 image_kib=16384 render_us=1210 \
 *           decode_us=40 total_us=2400
 *   paint   seq=12 pw=1200 ph=800 rects=1 blit_us=694
 *
 * `images_us` is CONTAINED IN `render_us` — the uploads happen inside the
 * display-list walk, so a reducer that wants exclusive draw cost subtracts.
 * `flushed` is how many cached bitmaps that step's target rebuild threw
 * away, which is the count `images_n` then re-uploads. */
class GpuProfileLog {
public:
    static GpuProfileLog &shared() {
        static GpuProfileLog log;
        return log;
    }

    bool active() const { return file_ != nullptr; }

    void line(const char *format, ...) {
        if (!file_) return;
        char text[512];
        va_list args;
        va_start(args, format);
        const int written = vsnprintf(text, sizeof(text), format, args);
        va_end(args);
        if (written <= 0) return;
        fputs(text, file_);
        /* Every line carries the monotonic clock, appended rather than
         * prefixed so the record type still leads the line. Per-event
         * durations cannot answer the question a resize actually poses —
         * how far apart a surface's consecutive frames land — and that
         * needs a wall clock, not a sequence number. Stamped at write
         * time, i.e. immediately after the span the line reports. */
        fprintf(file_, " t_us=%llu\n",
            static_cast<unsigned long long>(gpuClockNs() / 1000ULL));
        /* Buffered, not per-line flushed: a synchronous write inside a
         * measured frame would show up in the very numbers being measured.
         * 64 lines is well under a second of drag at any refresh rate, and
         * the destructor closes the file on a clean exit. */
        if (++pending_ >= 64) {
            fflush(file_);
            pending_ = 0;
        }
    }

private:
    GpuProfileLog() {
        wchar_t path[MAX_PATH] = {};
        const DWORD length = GetEnvironmentVariableW(L"NATIVE_SDK_GPU_PROFILE", path, MAX_PATH);
        if (length == 0 || length >= MAX_PATH) return;
        file_ = _wfopen(path, L"w");
        if (!file_) return;
        fputs("# native-sdk gpu surface profile: times in microseconds, images_us is inside render_us,"
              " t_us is a monotonic stamp taken as the line is written\n", file_);
    }

    ~GpuProfileLog() {
        if (!file_) return;
        fflush(file_);
        fclose(file_);
    }

    FILE *file_ = nullptr;
    unsigned pending_ = 0;
};

static bool gpuProfileActive() {
    return GpuProfileLog::shared().active();
}

/* Adds its scope's elapsed span to `sink`. The probed functions have
 * several return paths each, and a hand-placed stop before every one of
 * them is exactly the kind of thing that silently stops covering a path
 * someone adds later. Constructed inactive it reads no clock at all. */
class GpuProfileSpan {
public:
    GpuProfileSpan(bool active, uint64_t *sink)
        : sink_(active ? sink : nullptr), begin_ns_(sink_ ? gpuClockNs() : 0) {}
    ~GpuProfileSpan() {
        if (sink_) *sink_ += gpuClockNs() - begin_ns_;
    }
    GpuProfileSpan(const GpuProfileSpan &) = delete;
    GpuProfileSpan &operator=(const GpuProfileSpan &) = delete;

private:
    uint64_t *sink_;
    uint64_t begin_ns_;
};

static uint64_t gpuProfileMicros(uint64_t nanoseconds) {
    return (nanoseconds + 500) / 1000;
}

struct Point {
    float x = 0;
    float y = 0;
};

struct Rect {
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
};

struct Radius {
    float top_left = 0;
    float top_right = 0;
    float bottom_right = 0;
    float bottom_left = 0;
};

struct Color {
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 1;
};

struct Affine {
    float a = 1;
    float b = 0;
    float c = 0;
    float d = 1;
    float tx = 0;
    float ty = 0;
};

constexpr float maxTransformAxisLengthSquared(const Affine &matrix) {
    const float x_scale_squared = matrix.a * matrix.a + matrix.b * matrix.b;
    const float y_scale_squared = matrix.c * matrix.c + matrix.d * matrix.d;
    return x_scale_squared > y_scale_squared ? x_scale_squared : y_scale_squared;
}

static float transformScale(const Affine &matrix) {
    return std::max(0.0001f, std::sqrt(maxTransformAxisLengthSquared(matrix)));
}

static_assert(maxTransformAxisLengthSquared(Affine{2, 0, 0, 2, 0, 0}) == 4,
    "uniform command scaling must scale effect kernels");
static_assert(maxTransformAxisLengthSquared(Affine{0, 3, -2, 0, 0, 0}) == 9,
    "rotated nonuniform transforms use their largest axis scale");

static Rect normalized(Rect rect) {
    if (rect.width < 0) {
        rect.x += rect.width;
        rect.width = -rect.width;
    }
    if (rect.height < 0) {
        rect.y += rect.height;
        rect.height = -rect.height;
    }
    return rect;
}

static bool empty(Rect rect) {
    rect = normalized(rect);
    return rect.width <= 0 || rect.height <= 0;
}

static bool intersects(Rect left, Rect right) {
    left = normalized(left);
    right = normalized(right);
    return left.x < right.x + right.width && right.x < left.x + left.width &&
        left.y < right.y + right.height && right.y < left.y + left.height;
}

static Rect intersection(Rect left, Rect right) {
    left = normalized(left);
    right = normalized(right);
    const float x0 = std::max(left.x, right.x);
    const float y0 = std::max(left.y, right.y);
    const float x1 = std::min(left.x + left.width, right.x + right.width);
    const float y1 = std::min(left.y + left.height, right.y + right.height);
    return {x0, y0, std::max(0.0f, x1 - x0), std::max(0.0f, y1 - y0)};
}

static bool contains(Rect rect, double x, double y) {
    rect = normalized(rect);
    return x >= rect.x && y >= rect.y && x < rect.x + rect.width && y < rect.y + rect.height;
}

static D2D1_RECT_F d2dRect(Rect rect) {
    rect = normalized(rect);
    return D2D1::RectF(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
}

static Rect transformedRect(Rect rect, const Affine &matrix) {
    rect = normalized(rect);
    const Point corners[4] = {
        {rect.x, rect.y},
        {rect.x + rect.width, rect.y},
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
    };
    float x0 = std::numeric_limits<float>::infinity();
    float y0 = std::numeric_limits<float>::infinity();
    float x1 = -std::numeric_limits<float>::infinity();
    float y1 = -std::numeric_limits<float>::infinity();
    for (const Point &point : corners) {
        const float x = point.x * matrix.a + point.y * matrix.c + matrix.tx;
        const float y = point.x * matrix.b + point.y * matrix.d + matrix.ty;
        x0 = std::min(x0, x);
        y0 = std::min(y0, y);
        x1 = std::max(x1, x);
        y1 = std::max(y1, y);
    }
    return {x0, y0, x1 - x0, y1 - y0};
}

static D2D1_COLOR_F d2dColor(Color color, float opacity = 1.0f) {
    return D2D1::ColorF(clamp01(color.r), clamp01(color.g), clamp01(color.b), clamp01(color.a * opacity));
}

static uint32_t packedColor(Color color) {
    const uint32_t r = static_cast<uint32_t>(std::lround(clamp01(color.r) * 255.0f));
    const uint32_t g = static_cast<uint32_t>(std::lround(clamp01(color.g) * 255.0f));
    const uint32_t b = static_cast<uint32_t>(std::lround(clamp01(color.b) * 255.0f));
    const uint32_t a = static_cast<uint32_t>(std::lround(clamp01(color.a) * 255.0f));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

class Reader {
public:
    Reader(const uint8_t *bytes, size_t length) : bytes_(bytes), length_(length) {}

    bool failed() const { return failed_; }
    bool finished() const { return !failed_ && offset_ == length_; }
    size_t remaining() const { return offset_ <= length_ ? length_ - offset_ : 0; }

    bool bytes(void *destination, size_t count) {
        if (!has(count)) return false;
        if (count) std::memcpy(destination, bytes_ + offset_, count);
        offset_ += count;
        return true;
    }

    uint8_t u8() {
        uint8_t value = 0;
        bytes(&value, sizeof(value));
        return value;
    }

    uint16_t u16() {
        uint8_t raw[2] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        return static_cast<uint16_t>(raw[0]) |
            static_cast<uint16_t>(static_cast<uint16_t>(raw[1]) << 8);
    }

    uint32_t u32() {
        uint8_t raw[4] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        return static_cast<uint32_t>(raw[0]) |
            (static_cast<uint32_t>(raw[1]) << 8) |
            (static_cast<uint32_t>(raw[2]) << 16) |
            (static_cast<uint32_t>(raw[3]) << 24);
    }

    uint64_t u64() {
        uint8_t raw[8] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        uint64_t value = 0;
        for (unsigned index = 0; index < 8; ++index) value |= static_cast<uint64_t>(raw[index]) << (index * 8);
        return value;
    }

    float f32() {
        const uint32_t bits = u32();
        float value = 0;
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value)) failed_ = true;
        return value;
    }

    std::string string() {
        const uint32_t count = u32();
        if (!has(count)) return {};
        std::string value(reinterpret_cast<const char *>(bytes_ + offset_), count);
        offset_ += count;
        return value;
    }

    void fail() { failed_ = true; }

private:
    bool has(size_t count) {
        if (failed_ || count > remaining()) {
            failed_ = true;
            return false;
        }
        return true;
    }

    const uint8_t *bytes_ = nullptr;
    size_t length_ = 0;
    size_t offset_ = 0;
    bool failed_ = false;
};

static Point readPoint(Reader &reader) {
    return {reader.f32(), reader.f32()};
}

static Rect readRect(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

static Radius readRadius(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

static Color readColor(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

struct PathElement {
    enum class Verb : uint8_t { move, line, quadratic, cubic, close };
    Verb verb = Verb::move;
    Point points[3] = {};
};

struct Shape {
    enum class Kind : uint8_t { none, rect, rounded_rect, stroke_rect, line, path };
    Kind kind = Kind::none;
    Rect rect = {};
    Radius radius = {};
    Point from = {};
    Point to = {};
    float width = 1;
    std::vector<PathElement> path;
};

struct GradientStop {
    float offset = 0;
    Color color = {};
};

struct Paint {
    enum class Kind : uint8_t { none, color, linear_gradient };
    Kind kind = Kind::none;
    Color color = {};
    Point start = {};
    Point end = {};
    std::vector<GradientStop> stops;
};

struct ImageCommand {
    uint64_t id = 0;
    bool has_src = false;
    Rect src = {};
    Rect dst = {};
    float opacity = 1;
    uint8_t fit = 0;
    uint8_t sampling = 1;
    Radius radius = {};
};

struct TextLine {
    float x = 0;
    float baseline = 0;
    std::string text;
};

struct PositionedGlyph {
    uint16_t id = 0;
    uint64_t font_id = 0;
    float x = 0;
    float baseline = 0;
    float advance = 0;
};

struct PositionedTextFragment {
    float x = 0;
    float baseline = 0;
    std::string text;
};

struct TextCommand {
    uint64_t font_id = 0;
    float size = 12;
    Point origin = {};
    Color color = {};
    std::string text;
    bool has_positioned_glyphs = false;
    std::vector<PositionedGlyph> positioned_glyphs;
    std::vector<PositionedTextFragment> positioned_fragments;
    bool has_layout = false;
    float max_width = 0;
    float line_height = 0;
    uint8_t wrap = 1;
    uint8_t align = 0;
    bool has_lines = false;
    std::vector<TextLine> lines;
};

struct Effect {
    enum class Kind : uint8_t { none, shadow, blur };
    Kind kind = Kind::none;
    Rect rect = {};
    Radius radius = {};
    Point offset = {};
    float blur = 0;
    float spread = 0;
    Color color = {};
};

struct Command {
    uint8_t kind = 0xff;
    Rect bounds = {};
    float opacity = 1;
    float stroke_width = 1;
    uint8_t cap = 0;
    bool has_id = false;
    uint64_t id = 0;
    bool has_clip = false;
    Rect clip = {};
    bool has_transform = false;
    Affine transform = {};
    Shape shape;
    Paint paint;
    ImageCommand image;
    TextCommand text;
    Effect effect;
};

struct KeyedCommand {
    uint64_t key = 0;
    Command command;
};

struct ImageMeta {
    uint64_t id = 0;
    uint64_t fingerprint = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct ImageAction {
    uint8_t kind = 0;
    uint64_t id = 0;
    uint64_t fingerprint = 0;
    uint32_t image_index = UINT32_MAX;
};

struct DecodedPacket {
    uint8_t load_action = 0;
    uint64_t generation = 0;
    bool has_scissor = false;
    Rect scissor = {};
    std::vector<Rect> dirty_rects;
    std::vector<ImageMeta> images;
    std::vector<ImageAction> image_actions;
    std::vector<KeyedCommand> commands;
    std::vector<uint64_t> evicts;
    std::vector<KeyedCommand> upserts;
    std::vector<uint64_t> order;
};

static bool readShape(Reader &reader, Shape *shape) {
    switch (reader.u8()) {
        case 1:
            shape->kind = Shape::Kind::rect;
            shape->rect = readRect(reader);
            break;
        case 2:
            shape->kind = Shape::Kind::rounded_rect;
            shape->rect = readRect(reader);
            shape->radius = readRadius(reader);
            break;
        case 3:
            shape->kind = Shape::Kind::stroke_rect;
            shape->rect = readRect(reader);
            shape->radius = readRadius(reader);
            shape->width = reader.f32();
            break;
        case 4:
            shape->kind = Shape::Kind::line;
            shape->from = readPoint(reader);
            shape->to = readPoint(reader);
            shape->width = reader.f32();
            break;
        case 5: {
            shape->kind = Shape::Kind::path;
            const uint32_t count = reader.u32();
            if (reader.failed() || count > reader.remaining() || count > 65536) return false;
            shape->path.reserve(count);
            for (uint32_t index = 0; index < count; ++index) {
                PathElement element;
                const uint8_t verb = reader.u8();
                if (verb > 4) return false;
                element.verb = static_cast<PathElement::Verb>(verb);
                const size_t point_count = verb <= 1 ? 1 : (verb == 2 ? 2 : (verb == 3 ? 3 : 0));
                for (size_t point = 0; point < point_count; ++point) element.points[point] = readPoint(reader);
                shape->path.push_back(element);
            }
            break;
        }
        default:
            return false;
    }
    return !reader.failed();
}

static bool readPaint(Reader &reader, Paint *paint) {
    switch (reader.u8()) {
        case 1:
            paint->kind = Paint::Kind::color;
            paint->color = readColor(reader);
            break;
        case 2: {
            paint->kind = Paint::Kind::linear_gradient;
            paint->start = readPoint(reader);
            paint->end = readPoint(reader);
            const uint32_t count = reader.u32();
            if (reader.failed() || count > reader.remaining() || count > 4096) return false;
            paint->stops.reserve(count);
            for (uint32_t index = 0; index < count; ++index) {
                GradientStop stop;
                stop.offset = reader.f32();
                stop.color = readColor(reader);
                paint->stops.push_back(stop);
            }
            if (paint->stops.empty()) return false;
            break;
        }
        default:
            return false;
    }
    return !reader.failed();
}

static bool readImage(Reader &reader, ImageCommand *image) {
    image->id = reader.u64();
    image->has_src = reader.u8() != 0;
    if (image->has_src) image->src = readRect(reader);
    image->dst = readRect(reader);
    image->opacity = reader.f32();
    image->fit = reader.u8();
    image->sampling = reader.u8();
    image->radius = readRadius(reader);
    return !reader.failed() && image->id != 0 && image->fit <= 2 && image->sampling <= 1;
}

static bool readText(Reader &reader, TextCommand *text) {
    text->font_id = reader.u64();
    text->size = reader.f32();
    text->origin = readPoint(reader);
    text->color = readColor(reader);
    text->text = reader.string();
    text->has_positioned_glyphs = reader.u8() != 0;
    if (text->has_positioned_glyphs) {
        const uint32_t glyph_count = reader.u32();
        /* Every glyph consumes at least id u16 + flags u8 + three f32s;
         * font overrides add u64. Bound both allocation and framing. */
        if (reader.failed() || glyph_count > 65536 || glyph_count > reader.remaining() / 15) return false;
        text->positioned_glyphs.reserve(glyph_count);
        for (uint32_t index = 0; index < glyph_count; ++index) {
            PositionedGlyph glyph;
            glyph.id = reader.u16();
            const uint8_t flags = reader.u8();
            if (flags > 1) return false;
            glyph.font_id = (flags & 1) != 0 ? reader.u64() : text->font_id;
            glyph.x = reader.f32();
            glyph.baseline = reader.f32();
            glyph.advance = reader.f32();
            text->positioned_glyphs.push_back(glyph);
        }
        const uint32_t fragment_count = reader.u32();
        if (reader.failed() || fragment_count > 64 || fragment_count > reader.remaining() / 12) return false;
        text->positioned_fragments.reserve(fragment_count);
        for (uint32_t index = 0; index < fragment_count; ++index) {
            PositionedTextFragment fragment;
            fragment.x = reader.f32();
            fragment.baseline = reader.f32();
            fragment.text = reader.string();
            text->positioned_fragments.push_back(std::move(fragment));
        }
    }
    text->has_layout = reader.u8() != 0;
    if (!text->has_layout) return !reader.failed();
    text->max_width = reader.f32();
    text->line_height = reader.f32();
    text->wrap = reader.u8();
    text->align = reader.u8();
    if (text->wrap > 2 || text->align > 2) return false;
    text->has_lines = reader.u8() != 0;
    if (!text->has_lines) return !reader.failed();
    const uint32_t count = reader.u32();
    if (reader.failed() || count > reader.remaining() || count > 4096) return false;
    text->lines.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        TextLine line;
        line.x = reader.f32();
        line.baseline = reader.f32();
        line.text = reader.string();
        text->lines.push_back(std::move(line));
    }
    return !reader.failed();
}

static bool readEffect(Reader &reader, Effect *effect) {
    switch (reader.u8()) {
        case 1:
            effect->kind = Effect::Kind::shadow;
            effect->rect = readRect(reader);
            effect->radius = readRadius(reader);
            effect->offset = readPoint(reader);
            effect->blur = reader.f32();
            effect->spread = reader.f32();
            effect->color = readColor(reader);
            break;
        case 2:
            effect->kind = Effect::Kind::blur;
            effect->rect = readRect(reader);
            effect->blur = reader.f32();
            break;
        default:
            return false;
    }
    return !reader.failed();
}

enum : uint8_t {
    kCommandFlagId = 0x01,
    kCommandFlagClip = 0x02,
    kCommandFlagTransform = 0x04,
    kCommandFlagShape = 0x08,
    kCommandFlagPaint = 0x10,
    kCommandFlagImage = 0x20,
    kCommandFlagText = 0x40,
    kCommandFlagEffect = 0x80,
};

static bool readCommand(Reader &reader, Command *command) {
    command->kind = reader.u8();
    const uint8_t flags = reader.u8();
    command->bounds = readRect(reader);
    command->opacity = reader.f32();
    command->stroke_width = reader.f32();
    command->cap = reader.u8();
    if (reader.failed() || command->kind > 13 || command->cap > 1) return false;
    if (flags & kCommandFlagId) {
        command->has_id = true;
        command->id = reader.u64();
    }
    if (flags & kCommandFlagClip) {
        command->has_clip = true;
        command->clip = readRect(reader);
    }
    if (flags & kCommandFlagTransform) {
        command->has_transform = true;
        command->transform = {reader.f32(), reader.f32(), reader.f32(), reader.f32(), reader.f32(), reader.f32()};
    }
    if ((flags & kCommandFlagShape) && !readShape(reader, &command->shape)) return false;
    if ((flags & kCommandFlagPaint) && !readPaint(reader, &command->paint)) return false;
    if ((flags & kCommandFlagImage) && !readImage(reader, &command->image)) return false;
    if ((flags & kCommandFlagText) && !readText(reader, &command->text)) return false;
    if ((flags & kCommandFlagEffect) && !readEffect(reader, &command->effect)) return false;
    if (reader.failed()) return false;

    /* Treat the packet as an untrusted ABI boundary even though today's
     * producer lives in the same process. Every command kind has one
     * exact payload shape; accepting unrelated optional sections would
     * let a corrupt packet advance the reader successfully but silently
     * draw a different command than the bytes describe. */
    const uint8_t payload_flags = flags &
        (kCommandFlagShape | kCommandFlagPaint | kCommandFlagImage | kCommandFlagText | kCommandFlagEffect);
    switch (command->kind) {
        case 0:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rect && command->paint.kind == Paint::Kind::color;
        case 1:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 2:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rounded_rect && command->paint.kind == Paint::Kind::color;
        case 3:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rounded_rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 4:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::stroke_rect && command->paint.kind == Paint::Kind::color;
        case 5:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::stroke_rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 6:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::line && command->paint.kind == Paint::Kind::color;
        case 7:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::line && command->paint.kind == Paint::Kind::linear_gradient;
        case 8: case 9:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::path && command->paint.kind != Paint::Kind::none;
        case 10:
            return payload_flags == kCommandFlagImage && command->image.id != 0;
        case 11:
            /* The shared model keeps the text color both in the text
             * payload and in its resource paint metadata, so both
             * sections intentionally ride the canonical wire packet. */
            return payload_flags == (kCommandFlagPaint | kCommandFlagText) &&
                command->paint.kind == Paint::Kind::color;
        case 12:
            return payload_flags == kCommandFlagEffect && command->effect.kind == Effect::Kind::shadow;
        case 13:
            return payload_flags == kCommandFlagEffect && command->effect.kind == Effect::Kind::blur;
        default:
            return false;
    }
}

static bool readKeyedCommands(Reader &reader, std::vector<KeyedCommand> *commands, uint32_t count) {
    if (reader.failed() || count > kRetainedCommandCap || count > reader.remaining()) return false;
    commands->reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        KeyedCommand keyed;
        keyed.key = reader.u64();
        if (!readCommand(reader, &keyed.command)) return false;
        commands->push_back(std::move(keyed));
    }
    return true;
}

static bool decodePacket(const uint8_t *bytes, size_t length, DecodedPacket *packet) {
    if (!bytes || length < 16 || std::memcmp(bytes, "NSGP", 4) != 0) return false;
    Reader reader(bytes, length);
    uint8_t magic[4] = {};
    if (!reader.bytes(magic, sizeof(magic)) || reader.u8() != kPacketVersion) return false;
    packet->load_action = reader.u8();
    const uint8_t flags = reader.u8();
    (void)reader.u8();
    packet->generation = reader.u64();
    if (packet->load_action < 1 || packet->load_action > 3 || (flags & ~0x03u) != 0) return false;

    packet->has_scissor = (flags & 0x01) != 0;
    if (packet->has_scissor) packet->scissor = readRect(reader);
    if (flags & 0x02) {
        if (!packet->has_scissor) return false;
        const uint32_t count = reader.u32();
        if (reader.failed() || count == 0 || count > kDirtyRectCap) return false;
        packet->dirty_rects.reserve(count);
        for (uint32_t index = 0; index < count; ++index) packet->dirty_rects.push_back(readRect(reader));
    }

    const uint32_t image_count = reader.u32();
    if (reader.failed() || image_count > reader.remaining() || image_count > 65536) return false;
    packet->images.reserve(image_count);
    for (uint32_t index = 0; index < image_count; ++index) {
        ImageMeta image;
        image.id = reader.u64();
        image.fingerprint = reader.u64();
        image.width = reader.u32();
        image.height = reader.u32();
        packet->images.push_back(image);
    }

    const uint32_t action_count = reader.u32();
    if (reader.failed() || action_count > reader.remaining() || action_count > 65536) return false;
    packet->image_actions.reserve(action_count);
    for (uint32_t index = 0; index < action_count; ++index) {
        ImageAction action;
        action.kind = reader.u8();
        action.id = reader.u64();
        action.fingerprint = reader.u64();
        action.image_index = reader.u32();
        if (action.kind > 2) return false;
        packet->image_actions.push_back(action);
    }

    if (packet->load_action == 3) {
        const uint32_t evict_count = reader.u32();
        if (reader.failed() || evict_count > kRetainedCommandCap || evict_count > reader.remaining()) return false;
        packet->evicts.reserve(evict_count);
        for (uint32_t index = 0; index < evict_count; ++index) packet->evicts.push_back(reader.u64());

        const uint32_t upsert_count = reader.u32();
        if (!readKeyedCommands(reader, &packet->upserts, upsert_count)) return false;

        const uint32_t order_count = reader.u32();
        if (reader.failed() || order_count > kRetainedCommandCap || order_count > reader.remaining()) return false;
        packet->order.reserve(order_count);
        for (uint32_t index = 0; index < order_count; ++index) packet->order.push_back(reader.u64());
    } else {
        const uint32_t command_count = reader.u32();
        if (!readKeyedCommands(reader, &packet->commands, command_count)) return false;
    }
    return reader.finished();
}

struct ImageResource {
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t serial = 0;
    /* Direct2D's native 32-bit format: premultiplied BGRA, top-down. */
    std::vector<uint8_t> bgra;
};

constexpr bool imageActionResolvesResource(uint8_t kind) {
    return kind == 0 || kind == 1; /* upload or retain */
}

constexpr bool imageMetadataMatchesResource(
    bool resource_present,
    uint32_t metadata_width,
    uint32_t metadata_height,
    uint32_t resource_width,
    uint32_t resource_height
) {
    /* The renderer-wide store is authoritative. An absent entry is the
     * legitimate "not registered (yet/anymore)" state and draws nothing,
     * even though its packet metadata is therefore 0x0. */
    return !resource_present ||
        (metadata_width != 0 && metadata_height != 0 &&
            metadata_width == resource_width && metadata_height == resource_height);
}

static_assert(imageActionResolvesResource(0), "image uploads resolve the renderer-wide store");
static_assert(imageActionResolvesResource(1), "image retains reconcile the renderer-wide store");
static_assert(!imageActionResolvesResource(2), "image evictions only remove surface state");
static_assert(imageMetadataMatchesResource(false, 0, 0, 0, 0),
    "an unregistered image is a valid transient packet resource");
static_assert(imageMetadataMatchesResource(true, 64, 32, 64, 32),
    "a registered image must match its packet metadata");
static_assert(!imageMetadataMatchesResource(true, 64, 32, 32, 64),
    "mismatched registered-image metadata is rejected");

class FontBytesOwner final : public IUnknown {
public:
    explicit FontBytesOwner(const uint8_t *bytes, size_t length) : bytes_(bytes, bytes + length) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid == __uuidof(IUnknown)) {
            *object = static_cast<IUnknown *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG refs = --refs_;
        if (refs == 0) delete this;
        return refs;
    }

    const void *data() const { return bytes_.data(); }
    UINT32 size() const { return static_cast<UINT32>(bytes_.size()); }

private:
    std::atomic<ULONG> refs_{1};
    std::vector<uint8_t> bytes_;
};

struct FontResource {
    uint64_t token = 0;
    FontBytesOwner *owner = nullptr;
    IDWriteFontFile *file = nullptr;
    IDWriteFontCollection1 *collection = nullptr;
    std::wstring family;

    ~FontResource() {
        releaseCom(collection);
        releaseCom(file);
        releaseCom(owner);
    }
};

class GpuSurfaceImpl;

class GpuRendererImpl final : public WindowsGpuRenderer, public std::enable_shared_from_this<GpuRendererImpl> {
public:
    GpuRendererImpl() = default;
    ~GpuRendererImpl() override {
        fonts_.clear();
        images_.clear();
        releaseCom(font_fallback_);
        if (dwrite_factory_ && memory_font_loader_) dwrite_factory_->UnregisterFontFileLoader(memory_font_loader_);
        releaseCom(memory_font_loader_);
        releaseCom(dwrite_factory5_);
        releaseCom(dwrite_factory_);
        releaseDeviceStack();
        releaseCom(d2d_factory_);
    }

    bool initialize() {
        D2D1_FACTORY_OPTIONS options = {};
        /* ID2D1Factory1, not ID2D1Factory: the derived interface is what
         * owns `CreateDevice`, and it inherits every geometry and stroke
         * entry point `d2dFactory()` already hands out, so the ~8 existing
         * call sites are unchanged. */
        if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1),
                &options, reinterpret_cast<void **>(&d2d_factory_))) || !d2d_factory_) return false;
        IUnknown *unknown = nullptr;
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), &unknown)) || !unknown) return false;
        dwrite_factory_ = static_cast<IDWriteFactory *>(unknown);
        if (FAILED(dwrite_factory_->QueryInterface(__uuidof(IDWriteFactory5), reinterpret_cast<void **>(&dwrite_factory5_))) ||
            !dwrite_factory5_) return false;
        if (FAILED(dwrite_factory5_->CreateInMemoryFontFileLoader(&memory_font_loader_)) ||
            !memory_font_loader_) return false;
        if (FAILED(dwrite_factory_->RegisterFontFileLoader(memory_font_loader_))) return false;

        /* Text layout is planned against one explicit face and the engine's
         * deterministic .notdef advance. An empty custom fallback prevents
         * IDWriteTextLayout from silently substituting machine fonts for
         * missing glyphs; every created layout installs this object below. */
        IDWriteFontFallbackBuilder *fallback_builder = nullptr;
        HRESULT fallback_result = dwrite_factory5_->CreateFontFallbackBuilder(&fallback_builder);
        if (SUCCEEDED(fallback_result) && fallback_builder) {
            fallback_result = fallback_builder->CreateFontFallback(&font_fallback_);
        }
        releaseCom(fallback_builder);
        if (FAILED(fallback_result) || !font_fallback_) return false;

        /* The device stack is created eagerly here rather than lazily per
         * surface: one D3D11 device backs every gpu_surface in the
         * process, and a machine that cannot produce one at all should
         * fail the renderer now, so the runtime takes its software pixel
         * path from the first frame instead of discovering the problem
         * mid-drag. */
        return ensureDeviceStack();
    }

    /* Build D3D11 device -> IDXGIDevice -> ID2D1Device -> context.
     *
     * Idempotent, and safe to call again after `releaseDeviceStack()` --
     * which is what device-removal recovery will need once presentation
     * actually depends on this stack. */
    bool ensureDeviceStack() {
        if (d2d_context_) return true;
        releaseDeviceStack();
        if (!d2d_factory_) return false;

        /* BGRA_SUPPORT is mandatory for D2D interop. SINGLETHREADED
         * matches the D2D factory and the host's one-UI-thread model; it
         * drops D3D's internal locking. */
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED;
        static const D3D_FEATURE_LEVEL levels[] = {
            D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
            D3D_FEATURE_LEVEL_9_3, D3D_FEATURE_LEVEL_9_2, D3D_FEATURE_LEVEL_9_1,
        };
        /* An RDP session, a disabled adapter, or a machine with no D3D11
         * driver has no hardware device; WARP still composites correctly,
         * just on the CPU. `NATIVE_SDK_GPU_FORCE_WARP` exercises that path
         * on a machine that would otherwise never take it. */
        const bool force_warp = envFlagSet(L"NATIVE_SDK_GPU_FORCE_WARP");
        HRESULT result = force_warp ? E_FAIL : createD3DDevice(D3D_DRIVER_TYPE_HARDWARE, flags, levels);
        driver_type_ = D3D_DRIVER_TYPE_HARDWARE;
        if (FAILED(result)) {
            result = createD3DDevice(D3D_DRIVER_TYPE_WARP, flags, levels);
            driver_type_ = D3D_DRIVER_TYPE_WARP;
        }
        if (FAILED(result) || !d3d_device_) {
            releaseDeviceStack();
            return false;
        }

        IDXGIDevice *dxgi_device = nullptr;
        result = d3d_device_->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgi_device));
        if (SUCCEEDED(result) && dxgi_device) {
            /* The factory this surface's swap chain must come from is the
             * one that owns this device's adapter -- an independently
             * created DXGI factory produces a swap chain the device
             * cannot present through. Resolve it here, once. */
            IDXGIAdapter *adapter = nullptr;
            if (SUCCEEDED(dxgi_device->GetAdapter(&adapter)) && adapter) {
                DXGI_ADAPTER_DESC adapter_desc = {};
                if (SUCCEEDED(adapter->GetDesc(&adapter_desc))) {
                    WideCharToMultiByte(CP_UTF8, 0, adapter_desc.Description, -1,
                        adapter_name_, static_cast<int>(sizeof(adapter_name_)), nullptr, nullptr);
                }
                adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void **>(&dxgi_factory_));
            }
            releaseCom(adapter);
            result = d2d_factory_->CreateDevice(dxgi_device, &d2d_device_);
        }
        releaseCom(dxgi_device);
        if (SUCCEEDED(result) && d2d_device_) {
            result = d2d_device_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &d2d_context_);
        }
        if (FAILED(result) || !d2d_context_ || !dxgi_factory_) {
            releaseDeviceStack();
            return false;
        }
        device_generation_ += 1;
        if (gpuProfileActive()) {
            GpuProfileLog::shared().line("device driver=%s level=0x%04x generation=%llu adapter=\"%s\"",
                driver_type_ == D3D_DRIVER_TYPE_WARP ? "warp" : "hardware",
                static_cast<unsigned>(feature_level_),
                static_cast<unsigned long long>(device_generation_), adapter_name_);
        }
        return true;
    }

    void releaseDeviceStack() {
        releaseCom(d2d_context_);
        releaseCom(d2d_device_);
        releaseCom(dxgi_factory_);
        releaseCom(d3d_device_);
    }

    std::shared_ptr<WindowsGpuSurface> createSurface(HWND hwnd) override;

    bool uploadImage(uint64_t id, uint32_t width, uint32_t height, const uint8_t *rgba, size_t rgba_len) override {
        if (id == 0 || width == 0 || height == 0 || !rgba) return false;
        const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
        if (pixels > std::numeric_limits<size_t>::max() / 4 || rgba_len != pixels * 4) return false;
        auto resource = std::make_shared<ImageResource>();
        resource->width = width;
        resource->height = height;
        resource->serial = next_resource_serial_++;
        resource->bgra.resize(rgba_len);
        for (size_t index = 0; index < pixels; ++index) {
            const uint8_t *source = rgba + index * 4;
            uint8_t *destination = resource->bgra.data() + index * 4;
            const uint32_t alpha = source[3];
            destination[0] = static_cast<uint8_t>((static_cast<uint32_t>(source[2]) * alpha + 127) / 255);
            destination[1] = static_cast<uint8_t>((static_cast<uint32_t>(source[1]) * alpha + 127) / 255);
            destination[2] = static_cast<uint8_t>((static_cast<uint32_t>(source[0]) * alpha + 127) / 255);
            destination[3] = source[3];
        }
        images_[id] = std::move(resource);
        return true;
    }

    bool removeImage(uint64_t id) override {
        if (id == 0) return false;
        images_.erase(id);
        return true;
    }

    bool registerFont(uint64_t id, const uint8_t *ttf, size_t ttf_len, uint64_t *token) override {
        if (!token || id == 0 || !ttf || ttf_len == 0 || ttf_len > UINT32_MAX ||
            !dwrite_factory5_ || !memory_font_loader_) return false;

        auto resource = std::make_shared<FontResource>();
        resource->owner = new (std::nothrow) FontBytesOwner(ttf, ttf_len);
        if (!resource->owner) return false;
        if (FAILED(memory_font_loader_->CreateInMemoryFontFileReference(
                dwrite_factory_, resource->owner->data(), resource->owner->size(), resource->owner, &resource->file)) || !resource->file) {
            return false;
        }

        IDWriteFontSetBuilder1 *builder = nullptr;
        IDWriteFontSet *font_set = nullptr;
        HRESULT result = dwrite_factory5_->CreateFontSetBuilder(&builder);
        if (SUCCEEDED(result)) result = builder->AddFontFile(resource->file);
        if (SUCCEEDED(result)) result = builder->CreateFontSet(&font_set);
        if (SUCCEEDED(result)) result = dwrite_factory5_->CreateFontCollectionFromFontSet(font_set, &resource->collection);
        releaseCom(font_set);
        releaseCom(builder);
        if (FAILED(result) || !resource->collection || resource->collection->GetFontFamilyCount() == 0) return false;

        IDWriteFontFamily1 *family = nullptr;
        IDWriteLocalizedStrings *names = nullptr;
        result = resource->collection->GetFontFamily(0, &family);
        if (SUCCEEDED(result)) result = family->GetFamilyNames(&names);
        UINT32 length = 0;
        if (SUCCEEDED(result)) result = names->GetStringLength(0, &length);
        if (SUCCEEDED(result)) {
            resource->family.resize(static_cast<size_t>(length) + 1);
            result = names->GetString(0, resource->family.data(), length + 1);
            if (SUCCEEDED(result)) resource->family.resize(length);
        }
        releaseCom(names);
        releaseCom(family);
        if (FAILED(result) || resource->family.empty()) return false;

        resource->token = next_font_token_++;
        if (resource->token == 0) resource->token = next_font_token_++;
        fonts_[id] = resource;
        *token = resource->token;
        return true;
    }

    bool unregisterFont(uint64_t id, uint64_t token) override {
        auto found = fonts_.find(id);
        if (found != fonts_.end() && found->second->token == token) fonts_.erase(found);
        return true;
    }

    /* Bumped every time the device stack is (re)built. Surfaces stamp
     * the generation they built against and compare, which is how a
     * device loss reaches them without the renderer having to keep a
     * registry of live surfaces. */
    uint64_t deviceGeneration() const { return device_generation_; }

    /* HRESULTs that mean "this device is gone, rebuild everything", as
     * opposed to D2DERR_RECREATE_TARGET, which means only the target
     * went and the device is still good. */
    static bool deviceLost(HRESULT result) {
        return result == DXGI_ERROR_DEVICE_REMOVED || result == DXGI_ERROR_DEVICE_RESET ||
            result == DXGI_ERROR_DEVICE_HUNG || result == DXGI_ERROR_DRIVER_INTERNAL_ERROR ||
            result == D2DERR_RECREATE_TARGET;
    }

    /* Tear the whole stack down and build a new one. Surfaces discover
     * this through the generation counter and drop their own resources
     * -- every backing bitmap, swap chain, and cached texture belongs to
     * the device that just died. Returns false if the machine cannot
     * produce a device at all now, in which case surfaces stay dark and
     * the runtime keeps taking its software path. */
    bool recoverDeviceStack() {
        HRESULT reason = S_OK;
        if (d3d_device_) reason = d3d_device_->GetDeviceRemovedReason();
        releaseDeviceStack();
        const bool recovered = ensureDeviceStack();
        if (gpuProfileActive()) {
            GpuProfileLog::shared().line("device-lost reason=0x%08x recovered=%d generation=%llu",
                static_cast<unsigned>(reason), recovered ? 1 : 0,
                static_cast<unsigned long long>(device_generation_));
        }
        return recovered;
    }

    ID2D1Factory1 *d2dFactory() const { return d2d_factory_; }
    ID3D11Device *d3dDevice() const { return d3d_device_; }
    ID2D1Device *d2dDevice() const { return d2d_device_; }
    /* One context shared by every surface. Direct2D device contexts are
     * cheap to retarget (`SetTarget`) and expensive to multiply -- each
     * one carries its own command buffer against the same device. */
    ID2D1DeviceContext *d2dContext() const { return d2d_context_; }
    /* The adapter's own factory (never an independently created one --
     * a swap chain from a foreign factory cannot present this device). */
    IDXGIFactory2 *dxgiFactory() const { return dxgi_factory_; }
    IDWriteFactory *dwriteFactory() const { return dwrite_factory_; }
    IDWriteFontFallback *fontFallback() const { return font_fallback_; }

    std::shared_ptr<ImageResource> image(uint64_t id) const {
        auto found = images_.find(id);
        return found == images_.end() ? nullptr : found->second;
    }

    std::shared_ptr<FontResource> font(uint64_t id) const {
        auto found = fonts_.find(id);
        return found == fonts_.end() ? nullptr : found->second;
    }

private:
    HRESULT createD3DDevice(D3D_DRIVER_TYPE driver, UINT flags, const D3D_FEATURE_LEVEL (&levels)[7]) {
        HRESULT result = D3D11CreateDevice(nullptr, driver, nullptr, flags, levels,
            static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION, &d3d_device_, &feature_level_, nullptr);
        /* A driver older than the 11_1 runtime rejects the whole list
         * rather than negotiating down, so retry without that first
         * entry. This is the documented shape of the call. */
        if (result == E_INVALIDARG) {
            result = D3D11CreateDevice(nullptr, driver, nullptr, flags, levels + 1,
                static_cast<UINT>(std::size(levels)) - 1, D3D11_SDK_VERSION, &d3d_device_, &feature_level_, nullptr);
        }
        if (FAILED(result)) releaseCom(d3d_device_);
        return result;
    }

    ID2D1Factory1 *d2d_factory_ = nullptr;
    ID3D11Device *d3d_device_ = nullptr;
    IDXGIFactory2 *dxgi_factory_ = nullptr;
    ID2D1Device *d2d_device_ = nullptr;
    ID2D1DeviceContext *d2d_context_ = nullptr;
    uint64_t device_generation_ = 0;
    D3D_DRIVER_TYPE driver_type_ = D3D_DRIVER_TYPE_UNKNOWN;
    D3D_FEATURE_LEVEL feature_level_ = static_cast<D3D_FEATURE_LEVEL>(0);
    char adapter_name_[128] = {};
    IDWriteFactory *dwrite_factory_ = nullptr;
    IDWriteFactory5 *dwrite_factory5_ = nullptr;
    IDWriteInMemoryFontFileLoader *memory_font_loader_ = nullptr;
    IDWriteFontFallback *font_fallback_ = nullptr;
    std::map<uint64_t, std::shared_ptr<ImageResource>> images_;
    std::map<uint64_t, std::shared_ptr<FontResource>> fonts_;
    uint64_t next_resource_serial_ = 1;
    uint64_t next_font_token_ = 1;
};

static bool makeRoundedGeometry(ID2D1Factory *factory, Rect input, Radius input_radius, ID2D1PathGeometry **geometry) {
    if (!factory || !geometry) return false;
    *geometry = nullptr;
    const Rect rect = normalized(input);
    const float limit = std::max(0.0f, std::min(rect.width, rect.height) * 0.5f);
    const float tl = std::max(0.0f, std::min(limit, input_radius.top_left));
    const float tr = std::max(0.0f, std::min(limit, input_radius.top_right));
    const float br = std::max(0.0f, std::min(limit, input_radius.bottom_right));
    const float bl = std::max(0.0f, std::min(limit, input_radius.bottom_left));
    ID2D1PathGeometry *path = nullptr;
    ID2D1GeometrySink *sink = nullptr;
    HRESULT result = factory->CreatePathGeometry(&path);
    if (SUCCEEDED(result)) result = path->Open(&sink);
    if (FAILED(result) || !sink) {
        releaseCom(sink);
        releaseCom(path);
        return false;
    }

    const float x0 = rect.x;
    const float y0 = rect.y;
    const float x1 = rect.x + rect.width;
    const float y1 = rect.y + rect.height;
    sink->BeginFigure(D2D1::Point2F(x0 + tl, y0), D2D1_FIGURE_BEGIN_FILLED);
    sink->AddLine(D2D1::Point2F(x1 - tr, y0));
    if (tr > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x1 - tr + tr * kBezierCircle, y0),
        D2D1::Point2F(x1, y0 + tr - tr * kBezierCircle),
        D2D1::Point2F(x1, y0 + tr)));
    else sink->AddLine(D2D1::Point2F(x1, y0));
    sink->AddLine(D2D1::Point2F(x1, y1 - br));
    if (br > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x1, y1 - br + br * kBezierCircle),
        D2D1::Point2F(x1 - br + br * kBezierCircle, y1),
        D2D1::Point2F(x1 - br, y1)));
    else sink->AddLine(D2D1::Point2F(x1, y1));
    sink->AddLine(D2D1::Point2F(x0 + bl, y1));
    if (bl > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x0 + bl - bl * kBezierCircle, y1),
        D2D1::Point2F(x0, y1 - bl + bl * kBezierCircle),
        D2D1::Point2F(x0, y1 - bl)));
    else sink->AddLine(D2D1::Point2F(x0, y1));
    sink->AddLine(D2D1::Point2F(x0, y0 + tl));
    if (tl > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x0, y0 + tl - tl * kBezierCircle),
        D2D1::Point2F(x0 + tl - tl * kBezierCircle, y0),
        D2D1::Point2F(x0 + tl, y0)));
    else sink->AddLine(D2D1::Point2F(x0, y0));
    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    result = sink->Close();
    releaseCom(sink);
    if (FAILED(result)) {
        releaseCom(path);
        return false;
    }
    *geometry = path;
    return true;
}

static bool makePathGeometry(ID2D1Factory *factory, const Shape &shape, bool filled, ID2D1PathGeometry **geometry) {
    if (!factory || !geometry || shape.kind != Shape::Kind::path) return false;
    *geometry = nullptr;
    ID2D1PathGeometry *path = nullptr;
    ID2D1GeometrySink *sink = nullptr;
    HRESULT result = factory->CreatePathGeometry(&path);
    if (SUCCEEDED(result)) result = path->Open(&sink);
    if (FAILED(result) || !sink) {
        releaseCom(sink);
        releaseCom(path);
        return false;
    }
    bool figure_open = false;
    for (const PathElement &element : shape.path) {
        switch (element.verb) {
            case PathElement::Verb::move:
                if (figure_open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
                sink->BeginFigure(D2D1::Point2F(element.points[0].x, element.points[0].y),
                    filled ? D2D1_FIGURE_BEGIN_FILLED : D2D1_FIGURE_BEGIN_HOLLOW);
                figure_open = true;
                break;
            case PathElement::Verb::line:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddLine(D2D1::Point2F(element.points[0].x, element.points[0].y));
                break;
            case PathElement::Verb::quadratic:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(
                    D2D1::Point2F(element.points[0].x, element.points[0].y),
                    D2D1::Point2F(element.points[1].x, element.points[1].y)));
                break;
            case PathElement::Verb::cubic:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddBezier(D2D1::BezierSegment(
                    D2D1::Point2F(element.points[0].x, element.points[0].y),
                    D2D1::Point2F(element.points[1].x, element.points[1].y),
                    D2D1::Point2F(element.points[2].x, element.points[2].y)));
                break;
            case PathElement::Verb::close:
                if (!figure_open) { result = E_INVALIDARG; }
                else {
                    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
                    figure_open = false;
                }
                break;
        }
        if (FAILED(result)) break;
    }
    if (figure_open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    if (SUCCEEDED(result)) result = sink->Close();
    releaseCom(sink);
    if (FAILED(result)) {
        releaseCom(path);
        return false;
    }
    *geometry = path;
    return true;
}

class GpuSurfaceImpl final : public WindowsGpuSurface {
public:
    GpuSurfaceImpl(std::shared_ptr<GpuRendererImpl> renderer, HWND hwnd) : renderer_(std::move(renderer)), hwnd_(hwnd) {
        static unsigned next_surface_id = 0;
        surface_id_ = ++next_surface_id;
        D2D1_STROKE_STYLE_PROPERTIES style = D2D1::StrokeStyleProperties();
        style.startCap = D2D1_CAP_STYLE_FLAT;
        style.endCap = D2D1_CAP_STYLE_FLAT;
        style.dashCap = D2D1_CAP_STYLE_FLAT;
        style.lineJoin = D2D1_LINE_JOIN_MITER;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &rect_stroke_);
        style.lineJoin = D2D1_LINE_JOIN_ROUND;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &butt_stroke_);
        style.startCap = D2D1_CAP_STYLE_ROUND;
        style.endCap = D2D1_CAP_STYLE_ROUND;
        style.dashCap = D2D1_CAP_STYLE_ROUND;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &round_stroke_);
    }

    ~GpuSurfaceImpl() override {
        releaseDeviceResources(false);
        releaseCom(round_stroke_);
        releaseCom(butt_stroke_);
        releaseCom(rect_stroke_);
    }

    int present(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) override;
    bool paint(const RECT *paint_rects, size_t paint_rect_count) override;
    void abandonContent() override { releaseDeviceResources(true); }
    bool hasContent() const override { return content_valid_ && backing_bitmap_; }
    bool readColorAt(double logical_x, double logical_y, uint32_t *color) override;
    uint32_t representativeColorAt(double logical_x, double logical_y) const override;

private:
    /* The real bodies. `present`/`paint` are thin wrappers that exist only
     * so the `NATIVE_SDK_GPU_PROFILE` accumulators are reset and emitted on
     * exactly one path each — these two have a dozen refusal returns
     * between them, and per-return bookkeeping would rot on the first one
     * someone adds. */
    int presentPacket(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info);
    bool paintRects(const RECT *paint_rects, size_t paint_rect_count);

    struct CachedBitmap {
        uint64_t serial = 0;
        ID2D1Bitmap *bitmap = nullptr;
    };

    void releaseImageBitmaps() {
        for (auto &entry : image_bitmaps_) releaseCom(entry.second.bitmap);
        image_bitmaps_.clear();
    }

    void releaseImageBitmap(uint64_t id) {
        auto found = image_bitmaps_.find(id);
        if (found == image_bitmaps_.end()) return;
        releaseCom(found->second.bitmap);
        image_bitmaps_.erase(found);
    }

    /* One device context, shared by every surface on the renderer. It
     * carries no per-surface state of its own: each render and each paint
     * sets its target and DPI before drawing (`beginOn`). */
    ID2D1DeviceContext *ctx() const { return renderer_->d2dContext(); }

    /* Point the shared context at one of this surface's bitmaps, with
     * this surface's DPI, and open a draw. Every BeginDraw in this file
     * goes through here so the target can never be whatever the previous
     * surface left bound. */
    void beginOn(ID2D1Bitmap1 *target) {
        ctx()->SetTarget(target);
        ctx()->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        ctx()->BeginDraw();
        ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
    }

    /* Close the draw and unbind. Unbinding matters: a bound target holds
     * a reference, and `ResizeBuffers` fails while any reference to a
     * back buffer is outstanding. */
    HRESULT endOn() {
        const HRESULT result = ctx()->EndDraw();
        ctx()->SetTarget(nullptr);
        return result;
    }

    /* Adopt the renderer's current device generation, dropping every
     * resource built against the previous one. Called before any frame
     * work: a surface whose device was removed holds a backing bitmap, a
     * swap chain, and a texture cache that all belong to a dead device,
     * and none of them can be reused or repaired -- only released.
     *
     * Returns false when there is no usable device at all, which leaves
     * the surface contentless and the runtime on its software path. */
    bool syncDevice() {
        const uint64_t generation = renderer_->deviceGeneration();
        if (generation != device_generation_) {
            releaseDeviceResources(true);
            device_generation_ = generation;
        }
        return renderer_->d2dContext() != nullptr;
    }

    /* One exit for every lost-device HRESULT. Rebuilds the shared stack
     * (which bumps the generation, so sibling surfaces drop theirs on
     * their next frame) and clears this surface. The caller returns
     * false, which makes the host set `gpu_force_full_repaint_pending`
     * and ask the runtime for a full packet. */
    void handleDeviceLoss(HRESULT result) {
        if (GpuRendererImpl::deviceLost(result) && result != D2DERR_RECREATE_TARGET) {
            renderer_->recoverDeviceStack();
            device_generation_ = renderer_->deviceGeneration();
        }
        releaseDeviceResources(true);
    }

    void releaseDeviceResources(bool drop_retained) {
        releaseImageBitmaps();
        releaseCom(blur_snapshot_);
        releaseCom(readback_bitmap_);
        releaseCom(backing_bitmap_);
        releaseSwapChain();
        content_valid_ = false;
        if (drop_retained) {
            retained_valid_ = false;
            retained_commands_.clear();
            retained_order_.clear();
        }
    }

    void releaseSwapChain() {
        /* Order matters: the D2D bitmap holds the back buffer, and the
         * swap chain cannot be released cleanly underneath it. */
        if (ctx()) ctx()->SetTarget(nullptr);
        releaseCom(swap_bitmap_);
        releaseCom(swap_chain_);
        swap_width_ = 0;
        swap_height_ = 0;
        source_width_ = 0;
        source_height_ = 0;
        swap_bitmap_scale_ = 0;
        swap_background_applied_ = false;
        swap_last_damage_.clear();
        swap_history_valid_ = false;
    }

    /* Buffers are allocated on a grid, not at the client size.
     *
     * A drag delivers a new client size on every mouse step, and
     * `ResizeBuffers` on each of them is the most expensive single thing
     * in a resize frame: it frees and reallocates both back buffers, tears
     * down and rebuilds the D2D view of buffer 0, and re-associates the
     * chain with the window. Rounding the ALLOCATION up to a grid turns
     * that into once per granularity step of travel; every client size in
     * between is free, because SCALING_NONE simply crops the buffer to the
     * window (see `ensureSwapChain`).
     *
     * The grid costs at most one granularity step of over-allocation per
     * axis. At 128 px and 4 bytes per pixel that is well under a megabyte
     * on a panel-sized surface, and an editor with a dozen of them still
     * pays less than one 4K frame's worth in total. */
    static constexpr UINT kSwapAllocGranularityDefault = 128;

    /* `NATIVE_SDK_GPU_SWAP_GRANULARITY=<n>` overrides it, and `1` turns
     * the grid off entirely -- allocate exactly the client size, which is
     * the pre-grid behaviour. This earned its place: the first version of
     * this change also called `SetSourceSize`, which broke every surface
     * whose window is much shorter than its rounded-up buffer, and a
     * switch that separates over-allocating from what is done with the
     * over-allocation is what identified which half was at fault. Keep it
     * for the next such question, and as the escape hatch if a driver
     * disagrees about SCALING_NONE. */
    static UINT swapAllocGranularity() {
        static const UINT granularity = [] {
            const unsigned configured = envCount(L"NATIVE_SDK_GPU_SWAP_GRANULARITY");
            return configured > 0 ? static_cast<UINT>(configured) : kSwapAllocGranularityDefault;
        }();
        return granularity;
    }

    static UINT swapAllocExtent(UINT extent) {
        const UINT granularity = swapAllocGranularity();
        const UINT rounded = ((extent + granularity - 1) / granularity) * granularity;
        return rounded > 0 ? rounded : granularity;
    }

    /* FLIP_SEQUENTIAL, not FLIP_DISCARD: the renderer's incremental path
     * repaints only damaged regions, so undamaged pixels must survive
     * into the next frame. DISCARD would silently corrupt patch frames.
     *
     * SCALING_NONE is what makes an over-allocated buffer present
     * correctly at all. It aligns the buffer's top-left with the window's
     * and CLIPS rather than stretches, so a buffer larger than the window
     * shows exactly the window-sized top-left crop -- which is where this
     * renderer draws. It is also the one scaling mode `SetBackgroundColor`
     * applies to.
     *
     * `IDXGISwapChain2::SetSourceSize` is the interface DXGI documents for
     * "an effective resize without calling the more-expensive
     * ResizeBuffers", and it is deliberately NOT used here. Paired with
     * SCALING_NONE it renders wrong: a surface whose buffer is much taller
     * than its window (a 38 px header rounded up to a 128 px buffer) comes
     * out as a small fragment at the top-left on a field of background
     * colour. Measured on a real app, it is also worth nothing -- 0.428 ms
     * against 0.426 ms per resize step with it removed, which is noise.
     * The allocation grid below is doing all of the work; the source
     * region was only ever going to tell DWM something the clip already
     * says. */
    bool ensureSwapChain(UINT width, UINT height) {
        if (swap_chain_) {
            const bool too_small = width > swap_width_ || height > swap_height_;
            /* Reclaim only on a big shrink. Reallocating the moment the
             * client drops below the current grid cell would put the
             * ResizeBuffers back into every step of a shrinking drag,
             * which is the cost this whole scheme exists to avoid. */
            const bool wasteful = swap_width_ >= 2 * swapAllocExtent(width) ||
                swap_height_ >= 2 * swapAllocExtent(height);
            if ((too_small || wasteful) && !resizeSwapChain(width, height)) return false;
            if (!ensureSwapBitmap()) return false;
            return trackPresentedExtent(width, height);
        }
        if (!hwnd_ || !renderer_->dxgiFactory() || !renderer_->d3dDevice()) return false;

        DXGI_SWAP_CHAIN_DESC1 desc = {};
        desc.Width = swapAllocExtent(width);
        desc.Height = swapAllocExtent(height);
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_NONE;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        /* Top-level layered windows are refused long before this
         * renderer, so the surface is always opaque. */
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        if (FAILED(renderer_->dxgiFactory()->CreateSwapChainForHwnd(
                renderer_->d3dDevice(), hwnd_, &desc, nullptr, nullptr, &swap_chain_)) || !swap_chain_) {
            releaseSwapChain();
            return false;
        }
        /* The host owns Alt+Enter; DXGI's own handler would fight it. */
        renderer_->dxgiFactory()->MakeWindowAssociation(hwnd_, DXGI_MWA_NO_ALT_ENTER);
        swap_width_ = desc.Width;
        swap_height_ = desc.Height;
        swap_alloc_count_ += 1;
        if (!ensureSwapBitmap()) return false;
        return trackPresentedExtent(width, height);
    }

    bool resizeSwapChain(UINT width, UINT height) {
        /* Every reference to the back buffer must be gone first. */
        ctx()->SetTarget(nullptr);
        releaseCom(swap_bitmap_);
        swap_bitmap_scale_ = 0;
        const UINT alloc_width = swapAllocExtent(width);
        const UINT alloc_height = swapAllocExtent(height);
        if (FAILED(swap_chain_->ResizeBuffers(0, alloc_width, alloc_height, DXGI_FORMAT_UNKNOWN, 0))) {
            releaseSwapChain();
            return false;
        }
        swap_width_ = alloc_width;
        swap_height_ = alloc_height;
        swap_alloc_count_ += 1;
        /* Resized buffers hold undefined pixels, so the next paint owes a
         * full copy before any partial one can be correct. */
        swap_last_damage_.clear();
        swap_history_valid_ = false;
        return true;
    }

    /* The window-sized top-left crop of the buffers that SCALING_NONE
     * actually puts on screen. Nothing is called here -- DXGI derives the
     * crop from the window itself -- but every other part of this file
     * needs the number: it is what damage clamps to, what `exact`
     * compares against, and it is NOT the buffers' pixel size once the
     * allocation is rounded up.
     *
     * Recording it invalidates the damage history. Growing the crop
     * exposes buffer pixels this surface has never drawn, so the next copy
     * owes the whole thing -- one full copy per size change, which is what
     * a resize step costs anyway, minus the reallocation. */
    bool trackPresentedExtent(UINT width, UINT height) {
        if (width == source_width_ && height == source_height_) return true;
        source_width_ = width;
        source_height_ = height;
        swap_last_damage_.clear();
        swap_history_valid_ = false;
        return true;
    }

    bool ensureSwapBitmap() {
        /* A D2D bitmap's DPI is fixed at creation, so a monitor-scale
         * change has to rebuild the view even when the buffers did not
         * move. Every other caller is already gated on the buffers
         * changing, which is why this is the only place that checks. */
        if (swap_bitmap_ && swap_bitmap_scale_ == scale_) return true;
        if (swap_bitmap_) {
            ctx()->SetTarget(nullptr);
            releaseCom(swap_bitmap_);
        }
        IDXGISurface *surface = nullptr;
        if (FAILED(swap_chain_->GetBuffer(0, IID_PPV_ARGS(&surface))) || !surface) {
            releaseCom(surface);
            return false;
        }
        const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
            static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        const HRESULT result = ctx()->CreateBitmapFromDxgiSurface(surface, &properties, &swap_bitmap_);
        releaseCom(surface);
        if (FAILED(result) || !swap_bitmap_) return false;
        swap_bitmap_scale_ = scale_;
        return true;
    }

    /* The colour DXGI fills the window with wherever the presented region
     * does not reach it. That gap is not hypothetical: DWM keeps showing
     * the last present until the next one lands, so every window-expanding
     * drag step exposes a band for one frame. Left unset the fill is not
     * the app's -- it reads as a white flash along the growing edge, and
     * an app-adopted media surface that only repaints on a new video frame
     * can hold it far longer than one frame.
     *
     * The app's own clear colour is the right value by construction: it is
     * the colour that band is about to be painted, so filling it early is
     * indistinguishable from having drawn it. SCALING_NONE is a
     * precondition of the call (see the swap-chain description), and with
     * ALPHA_MODE_IGNORE the alpha channel is ignored. */
    void applyBackgroundColor() {
        if (!swap_chain_) return;
        if (swap_background_applied_ &&
            swap_background_.r == clear_color_.r &&
            swap_background_.g == clear_color_.g &&
            swap_background_.b == clear_color_.b) return;
        const DXGI_RGBA background = {
            clamp01(clear_color_.r), clamp01(clear_color_.g), clamp01(clear_color_.b), 1.0f};
        /* Refused on the Windows 7 platform update (E_NOTIMPL) and on any
         * scaling mode but NONE. Nothing downstream depends on it, so a
         * refusal only costs the flash it was there to prevent. */
        swap_background_applied_ = SUCCEEDED(swap_chain_->SetBackgroundColor(&background));
        if (swap_background_applied_) swap_background_ = clear_color_;
    }

    bool ensureTargets(double surface_width, double surface_height, double scale, uint32_t pixel_width, uint32_t pixel_height) {
        const bool profiling = gpuProfileActive();
        const GpuProfileSpan profile_span(profiling, &profile_targets_ns_);
        const bool dimensions_changed = backing_bitmap_ &&
            (pixel_width_ != pixel_width || pixel_height_ != pixel_height || scale_ != scale ||
             surface_width_ != surface_width || surface_height_ != surface_height);
        if (profiling) {
            profile_target_rebuild_ = dimensions_changed;
            profile_flushed_bitmaps_ = dimensions_changed ? image_bitmaps_.size() : 0;
        }
        if (dimensions_changed) {
            /* The image cache is NOT dropped here any more, and that is
             * the whole point of the migration.
             *
             * Under the blt model these bitmaps belonged to the backing
             * render target, which this branch recreated, so every one of
             * them had to go and be re-uploaded from CPU memory on the
             * next frame -- 1.5 ms per resize step at the runtime's
             * 16 MiB registry ceiling. They are created from the
             * `ID2D1Device` now, so they outlive any surface resize and
             * `ensureImageBitmap` keeps hitting its cache mid-drag.
             *
             * The two surfaces that genuinely are size-shaped still go:
             * the backing bitmap (a D2D bitmap's pixel size and DPI are
             * fixed at creation) and the blur snapshot (allocated at
             * surface size). */
            releaseCom(blur_snapshot_);
            releaseCom(backing_bitmap_);
            content_valid_ = false;
        }
        scale_ = scale;
        surface_width_ = surface_width;
        surface_height_ = surface_height;
        pixel_width_ = pixel_width;
        pixel_height_ = pixel_height;

        if (!renderer_->d2dContext()) return false;
        if (backing_bitmap_) return true;

        const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        const HRESULT result = ctx()->CreateBitmap(
            D2D1::SizeU(pixel_width_, pixel_height_), nullptr, 0, properties, &backing_bitmap_);
        return SUCCEEDED(result) && backing_bitmap_;
    }

    bool makeBrush(const Paint &paint, float opacity, ID2D1Brush **brush) {
        if (!brush || !backing_bitmap_) return false;
        *brush = nullptr;
        if (paint.kind == Paint::Kind::color) {
            ID2D1SolidColorBrush *solid = nullptr;
            if (FAILED(ctx()->CreateSolidColorBrush(d2dColor(paint.color, opacity), &solid))) return false;
            *brush = solid;
            return true;
        }
        if (paint.kind != Paint::Kind::linear_gradient || paint.stops.empty()) return false;
        std::vector<D2D1_GRADIENT_STOP> stops;
        stops.reserve(paint.stops.size());
        for (const GradientStop &source : paint.stops) {
            D2D1_GRADIENT_STOP stop = {};
            stop.position = clamp01(source.offset);
            stop.color = d2dColor(source.color, opacity);
            stops.push_back(stop);
        }
        ID2D1GradientStopCollection *collection = nullptr;
        ID2D1LinearGradientBrush *gradient = nullptr;
        HRESULT result = ctx()->CreateGradientStopCollection(
            stops.data(), static_cast<UINT32>(stops.size()), D2D1_GAMMA_2_2,
            D2D1_EXTEND_MODE_CLAMP, &collection);
        if (SUCCEEDED(result)) {
            result = ctx()->CreateLinearGradientBrush(
                D2D1::LinearGradientBrushProperties(
                    D2D1::Point2F(paint.start.x, paint.start.y),
                    D2D1::Point2F(paint.end.x, paint.end.y)), collection, &gradient);
        }
        releaseCom(collection);
        if (FAILED(result)) {
            releaseCom(gradient);
            return false;
        }
        *brush = gradient;
        return true;
    }

    bool makeShapeGeometry(const Shape &shape, bool filled, ID2D1Geometry **geometry) {
        if (!geometry) return false;
        *geometry = nullptr;
        if (shape.kind == Shape::Kind::rect) {
            ID2D1RectangleGeometry *rect = nullptr;
            if (FAILED(renderer_->d2dFactory()->CreateRectangleGeometry(d2dRect(shape.rect), &rect))) return false;
            *geometry = rect;
            return true;
        }
        if (shape.kind == Shape::Kind::rounded_rect || shape.kind == Shape::Kind::stroke_rect) {
            ID2D1PathGeometry *rounded = nullptr;
            if (!makeRoundedGeometry(renderer_->d2dFactory(), shape.rect, shape.radius, &rounded)) return false;
            *geometry = rounded;
            return true;
        }
        if (shape.kind == Shape::Kind::path) {
            ID2D1PathGeometry *path = nullptr;
            if (!makePathGeometry(renderer_->d2dFactory(), shape, filled, &path)) return false;
            *geometry = path;
            return true;
        }
        return false;
    }

    bool drawPaintedShape(const Command &command, bool stroke) {
        const float stroke_width = canvasStrokeWidth(
            command.shape.kind == Shape::Kind::line ? command.shape.width : command.stroke_width);
        /* Match the reference renderer: non-positive strokes are no-ops,
         * while positive fractional widths remain valid Direct2D widths. */
        if (stroke && stroke_width <= 0) return true;
        ID2D1Brush *brush = nullptr;
        if (!makeBrush(command.paint, clamp01(command.opacity), &brush)) return false;
        if (command.shape.kind == Shape::Kind::line) {
            if (!stroke) {
                releaseCom(brush);
                return false;
            }
            ctx()->DrawLine(
                D2D1::Point2F(command.shape.from.x, command.shape.from.y),
                D2D1::Point2F(command.shape.to.x, command.shape.to.y),
                brush, stroke_width, command.cap == 1 ? round_stroke_ : butt_stroke_);
            releaseCom(brush);
            return true;
        }
        ID2D1Geometry *geometry = nullptr;
        if (!makeShapeGeometry(command.shape, !stroke, &geometry)) {
            releaseCom(brush);
            return false;
        }
        if (stroke) {
            ID2D1StrokeStyle *stroke_style = command.shape.kind == Shape::Kind::stroke_rect
                ? rect_stroke_
                : (command.cap == 1 ? round_stroke_ : butt_stroke_);
            ctx()->DrawGeometry(geometry, brush, stroke_width, stroke_style);
        } else {
            ctx()->FillGeometry(geometry, brush);
        }
        releaseCom(geometry);
        releaseCom(brush);
        return true;
    }

    bool ensureImageBitmap(uint64_t id, ID2D1Bitmap **bitmap) {
        if (!bitmap || !backing_bitmap_) return false;
        *bitmap = nullptr;
        auto resource_found = image_cache_.find(id);
        if (resource_found == image_cache_.end() || !resource_found->second) return true;
        const std::shared_ptr<ImageResource> &resource = resource_found->second;
        CachedBitmap &cached = image_bitmaps_[id];
        if (cached.bitmap && cached.serial == resource->serial) {
            *bitmap = cached.bitmap;
            return true;
        }
        releaseCom(cached.bitmap);
        cached.serial = 0;
        const D2D1_BITMAP_PROPERTIES properties = D2D1::BitmapProperties(
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
        /* The measured cost this migration is about: a cache miss here is a
         * full CPU->GPU texture upload, and a resize step misses on every
         * live image because `ensureTargets` dropped the whole map. */
        const bool profiling = gpuProfileActive();
        const uint64_t upload_begin_ns = profiling ? gpuClockNs() : 0;
        HRESULT result = ctx()->CreateBitmap(
            D2D1::SizeU(resource->width, resource->height), resource->bgra.data(),
            resource->width * 4, properties, &cached.bitmap);
        if (profiling) {
            profile_image_ns_ += gpuClockNs() - upload_begin_ns;
            profile_image_uploads_ += 1;
            profile_image_bytes_ += resource->bgra.size();
        }
        if (FAILED(result) || !cached.bitmap) return false;
        cached.serial = resource->serial;
        *bitmap = cached.bitmap;
        return true;
    }

    bool drawImage(const Command &command) {
        ID2D1Bitmap *bitmap = nullptr;
        if (!ensureImageBitmap(command.image.id, &bitmap)) return false;
        if (!bitmap) return true; /* registered image not available yet */
        const auto resource_found = image_cache_.find(command.image.id);
        if (resource_found == image_cache_.end() || !resource_found->second) return true;
        const ImageResource &resource = *resource_found->second;

        Rect source = command.image.has_src ? normalized(command.image.src) :
            Rect{0, 0, static_cast<float>(resource.width), static_cast<float>(resource.height)};
        source = intersection(source, Rect{0, 0, static_cast<float>(resource.width), static_cast<float>(resource.height)});
        Rect requested = normalized(command.image.dst);
        if (empty(source) || empty(requested)) return false;
        Rect destination = requested;
        if (command.image.fit == 1 || command.image.fit == 2) {
            const float source_aspect = source.width / source.height;
            const float destination_aspect = requested.width / requested.height;
            float width = requested.width;
            float height = requested.height;
            if (command.image.fit == 1) {
                if (destination_aspect > source_aspect) width = height * source_aspect;
                else height = width / source_aspect;
            } else {
                if (destination_aspect > source_aspect) height = width / source_aspect;
                else width = height * source_aspect;
            }
            destination = {
                requested.x + (requested.width - width) * 0.5f,
                requested.y + (requested.height - height) * 0.5f,
                width,
                height,
            };
        }

        ID2D1Layer *layer = nullptr;
        ID2D1PathGeometry *mask = nullptr;
        const float max_radius = std::max(std::max(command.image.radius.top_left, command.image.radius.top_right),
            std::max(command.image.radius.bottom_right, command.image.radius.bottom_left));
        if (max_radius > 0) {
            if (!makeRoundedGeometry(renderer_->d2dFactory(), requested, command.image.radius, &mask) ||
                FAILED(ctx()->CreateLayer(nullptr, &layer))) {
                releaseCom(mask);
                releaseCom(layer);
                return false;
            }
            D2D1_LAYER_PARAMETERS parameters = D2D1::LayerParameters();
            parameters.contentBounds = D2D1::InfiniteRect();
            parameters.geometricMask = mask;
            parameters.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
            parameters.opacity = 1.0f;
            ctx()->PushLayer(parameters, layer);
        } else if (command.image.fit == 2) {
            /* Cover expands one destination axis past the requested frame.
             * A zero-radius image still has a rectangular destination mask;
             * without this clip the expanded bitmap paints over siblings. */
            ctx()->PushAxisAlignedClip(d2dRect(requested), D2D1_ANTIALIAS_MODE_ALIASED);
        }
        ctx()->DrawBitmap(bitmap, d2dRect(destination),
            clamp01(command.opacity * command.image.opacity),
            command.image.sampling == 0 ? D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR : D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
            d2dRect(source));
        if (layer) ctx()->PopLayer();
        else if (command.image.fit == 2) ctx()->PopAxisAlignedClip();
        releaseCom(layer);
        releaseCom(mask);
        return true;
    }

    static bool widenUtf8(const std::string &value, std::wstring *wide) {
        if (!wide) return false;
        wide->clear();
        if (value.empty()) return true;
        if (value.size() > INT_MAX) return false;
        const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (count <= 0) return false;
        wide->resize(static_cast<size_t>(count));
        return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), wide->data(), count) == count;
    }

    static DWRITE_FONT_WEIGHT canvasFontWeight(uint64_t font_id) {
        if (font_id == 3) return DWRITE_FONT_WEIGHT_MEDIUM;
        if (font_id == 4 || font_id == 6) return DWRITE_FONT_WEIGHT_BOLD;
        return DWRITE_FONT_WEIGHT_NORMAL;
    }

    static DWRITE_FONT_STYLE canvasFontStyle(uint64_t font_id) {
        return font_id == 5 || font_id == 6 ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
    }

    std::shared_ptr<FontResource> fontResource(uint64_t font_id) const {
        std::shared_ptr<FontResource> resource = renderer_->font(canvasFontResourceId(font_id));
        if (!resource) {
            const uint64_t fallback_id = canvasFallbackFontResourceId(font_id);
            if (fallback_id != 0) resource = renderer_->font(fallback_id);
        }
        return resource;
    }

    bool createGlyphFace(uint64_t font_id, IDWriteFontFace **face) const {
        if (!face) return false;
        *face = nullptr;
        const DWRITE_FONT_WEIGHT weight = canvasFontWeight(font_id);
        const DWRITE_FONT_STYLE style = canvasFontStyle(font_id);
        std::shared_ptr<FontResource> custom = fontResource(font_id);
        IDWriteFont *font = nullptr;
        HRESULT result = E_FAIL;
        if (custom) {
            IDWriteFontFamily1 *family = nullptr;
            result = custom->collection->GetFontFamily(0, &family);
            if (SUCCEEDED(result)) result = family->GetFirstMatchingFont(
                weight, DWRITE_FONT_STRETCH_NORMAL, style, &font);
            releaseCom(family);
        } else {
            IDWriteFontCollection *collection = nullptr;
            IDWriteFontFamily *family = nullptr;
            const wchar_t *family_name = font_id == 2 ? L"Consolas" : L"Segoe UI";
            UINT32 family_index = 0;
            BOOL exists = FALSE;
            result = renderer_->dwriteFactory()->GetSystemFontCollection(&collection);
            if (SUCCEEDED(result)) result = collection->FindFamilyName(family_name, &family_index, &exists);
            if (SUCCEEDED(result) && !exists) result = E_FAIL;
            if (SUCCEEDED(result)) result = collection->GetFontFamily(family_index, &family);
            if (SUCCEEDED(result)) result = family->GetFirstMatchingFont(
                weight, DWRITE_FONT_STRETCH_NORMAL, style, &font);
            releaseCom(family);
            releaseCom(collection);
        }
        if (SUCCEEDED(result) && font) result = font->CreateFontFace(face);
        releaseCom(font);
        return SUCCEEDED(result) && *face;
    }

    bool createTextFormat(const TextCommand &text, IDWriteTextFormat **format) {
        if (!format) return false;
        *format = nullptr;
        /* IDs 3..6 are styled variants of the built-in sans face, not
         * independent assets. Resolve them through registered Geist id 1
         * and let DirectWrite select/simulate the requested traits. */
        const uint64_t resource_id = canvasFontResourceId(text.font_id);
        std::shared_ptr<FontResource> custom = renderer_->font(resource_id);
        /* An absent application font follows the reference/AppKit fallback
         * contract too: mono keeps its platform mono fallback, every other
         * id uses bundled Geist when that registration succeeded. */
        if (!custom) {
            const uint64_t fallback_id = canvasFallbackFontResourceId(text.font_id);
            if (fallback_id != 0) custom = renderer_->font(fallback_id);
        }
        const wchar_t *family = L"Segoe UI";
        IDWriteFontCollection *collection = nullptr;
        const DWRITE_FONT_WEIGHT weight = canvasFontWeight(text.font_id);
        const DWRITE_FONT_STYLE style = canvasFontStyle(text.font_id);
        if (custom) {
            family = custom->family.c_str();
            collection = custom->collection;
        } else if (text.font_id == 2) family = L"Consolas";
        HRESULT result = renderer_->dwriteFactory()->CreateTextFormat(
            family, collection, weight, style, DWRITE_FONT_STRETCH_NORMAL,
            std::max(1.0f, text.size), L"en-us", format);
        if (FAILED(result) || !*format) return false;
        (*format)->SetTextAlignment(text.align == 1 ? DWRITE_TEXT_ALIGNMENT_CENTER :
            (text.align == 2 ? DWRITE_TEXT_ALIGNMENT_TRAILING : DWRITE_TEXT_ALIGNMENT_LEADING));
        (*format)->SetWordWrapping(text.wrap == 0 ? DWRITE_WORD_WRAPPING_NO_WRAP :
            (text.wrap == 2 ? DWRITE_WORD_WRAPPING_CHARACTER : DWRITE_WORD_WRAPPING_WRAP));
        if (text.line_height > 0) {
            (*format)->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, text.line_height, std::min(text.line_height, text.size));
        }
        return true;
    }

    bool createTextLayout(
        const std::wstring &value,
        IDWriteTextFormat *format,
        float width,
        float height,
        IDWriteTextLayout **layout
    ) {
        if (!format || !layout || !renderer_->fontFallback()) return false;
        *layout = nullptr;
        HRESULT result = renderer_->dwriteFactory()->CreateTextLayout(
            value.data(), static_cast<UINT32>(value.size()), format,
            std::max(1.0f, width), std::max(1.0f, height), layout);
        IDWriteTextLayout2 *layout2 = nullptr;
        if (SUCCEEDED(result) && *layout) {
            result = (*layout)->QueryInterface(
                __uuidof(IDWriteTextLayout2), reinterpret_cast<void **>(&layout2));
        }
        if (SUCCEEDED(result) && layout2) {
            result = layout2->SetFontFallback(renderer_->fontFallback());
        }
        releaseCom(layout2);
        if (FAILED(result)) {
            releaseCom(*layout);
            return false;
        }
        return *layout != nullptr;
    }

    bool drawText(const Command &command) {
        const TextCommand &text = command.text;
        IDWriteTextFormat *format = nullptr;
        ID2D1SolidColorBrush *brush = nullptr;
        if (!createTextFormat(text, &format) ||
            FAILED(ctx()->CreateSolidColorBrush(d2dColor(text.color, command.opacity), &brush))) {
            releaseCom(brush);
            releaseCom(format);
            return false;
        }

        auto draw_line = [&](const std::string &utf8, float x, float baseline) -> bool {
            if (utf8.empty()) return true;
            std::wstring value;
            if (!widenUtf8(utf8, &value)) return false;
            IDWriteTextLayout *layout = nullptr;
            HRESULT result = createTextLayout(
                value, format, 100000.0f, std::max(4.0f, text.size * 4.0f), &layout) ? S_OK : E_FAIL;
            DWRITE_LINE_METRICS metrics = {};
            UINT32 actual = 0;
            if (SUCCEEDED(result)) result = layout->GetLineMetrics(&metrics, 1, &actual);
            if (SUCCEEDED(result) && actual == 1) {
                ctx()->DrawTextLayout(D2D1::Point2F(x, baseline - metrics.baseline), layout, brush,
                    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            }
            releaseCom(layout);
            return SUCCEEDED(result) && actual == 1;
        };

        if (text.has_positioned_glyphs) {
            bool result = true;
            std::map<uint64_t, IDWriteFontFace *> faces;
            for (const PositionedGlyph &glyph : text.positioned_glyphs) {
                IDWriteFontFace *face = nullptr;
                auto found = faces.find(glyph.font_id);
                if (found == faces.end()) {
                    if (!createGlyphFace(glyph.font_id, &face)) {
                        result = false;
                        break;
                    }
                    faces[glyph.font_id] = face;
                } else {
                    face = found->second;
                }
                const UINT16 glyph_index = glyph.id;
                const FLOAT glyph_advance = glyph.advance;
                const DWRITE_GLYPH_OFFSET glyph_offset = {};
                DWRITE_GLYPH_RUN glyph_run = {};
                glyph_run.fontFace = face;
                glyph_run.fontEmSize = std::max(1.0f, text.size);
                glyph_run.glyphCount = 1;
                glyph_run.glyphIndices = &glyph_index;
                glyph_run.glyphAdvances = &glyph_advance;
                glyph_run.glyphOffsets = &glyph_offset;
                ctx()->DrawGlyphRun(
                    D2D1::Point2F(glyph.x, glyph.baseline), &glyph_run, brush, DWRITE_MEASURING_MODE_NATURAL);
            }
            if (result) {
                /* Positioned fragments already carry their final x; do not
                 * apply center/trailing alignment inside the wide one-line
                 * helper layout a second time. */
                format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
                for (const PositionedTextFragment &fragment : text.positioned_fragments) {
                    if (!draw_line(fragment.text, fragment.x, fragment.baseline)) {
                        result = false;
                        break;
                    }
                }
            }
            for (auto &entry : faces) releaseCom(entry.second);
            releaseCom(brush);
            releaseCom(format);
            return result;
        }

        bool result = true;
        if (text.has_layout && text.has_lines) {
            /* Engine-measured lines already carry their final aligned x.
             * Applying DirectWrite alignment again would center/trail the
             * run inside the deliberately wide one-line layout and move
             * short labels (counts, centered buttons) off the surface. */
            format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
            for (const TextLine &line : text.lines) {
                if (!draw_line(line.text, line.x, line.baseline)) {
                    result = false;
                    break;
                }
            }
        } else if (!text.has_layout) {
            /* A raw DrawText origin is a baseline, not the top of an em
             * box. DirectWrite's baseline comes from the registered face's
             * metrics and is not guaranteed to equal `size`, so use the
             * same measured-baseline path as engine-planned lines. */
            result = draw_line(text.text, text.origin.x, text.origin.y);
        } else {
            std::wstring value;
            result = widenUtf8(text.text, &value);
            if (result && !value.empty()) {
                const float width = text.max_width > 0 ? text.max_width : 100000.0f;
                const float height = std::max(text.line_height, text.size * 1.25f) * 4096.0f;
                IDWriteTextLayout *layout = nullptr;
                result = createTextLayout(value, format, width, height, &layout);
                if (result) {
                    ctx()->DrawTextLayout(
                        D2D1::Point2F(text.origin.x, text.origin.y - text.size), layout, brush,
                        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                }
                releaseCom(layout);
            }
        }
        releaseCom(brush);
        releaseCom(format);
        return result;
    }

    bool drawShadow(const Command &command) {
        const Effect &effect = command.effect;
        const float blur = std::max(0.0f, effect.blur);
        const unsigned steps = blur > 0.25f ? 12u : 1u;
        float weight_sum = 0;
        for (unsigned index = 0; index < steps; ++index) weight_sum += static_cast<float>(index + 1);
        for (unsigned index = 0; index < steps; ++index) {
            const float inward = static_cast<float>(index + 1) / static_cast<float>(steps);
            /* Spread is signed: negative values inset the shadow caster
             * before the blur halo expands it. The default card/overlay
             * tokens depend on that contraction. */
            const float expansion = effect.spread + blur * (1.0f - inward);
            Rect rect = normalized(effect.rect);
            rect.x += effect.offset.x - expansion;
            rect.y += effect.offset.y - expansion;
            rect.width += expansion * 2;
            rect.height += expansion * 2;
            if (rect.width <= 0 || rect.height <= 0) continue;
            Radius radius = effect.radius;
            radius.top_left = std::max(0.0f, radius.top_left + expansion);
            radius.top_right = std::max(0.0f, radius.top_right + expansion);
            radius.bottom_right = std::max(0.0f, radius.bottom_right + expansion);
            radius.bottom_left = std::max(0.0f, radius.bottom_left + expansion);
            ID2D1PathGeometry *geometry = nullptr;
            ID2D1SolidColorBrush *brush = nullptr;
            Color layer_color = effect.color;
            layer_color.a *= static_cast<float>(index + 1) / weight_sum;
            if (!makeRoundedGeometry(renderer_->d2dFactory(), rect, radius, &geometry) ||
                FAILED(ctx()->CreateSolidColorBrush(d2dColor(layer_color, command.opacity), &brush))) {
                releaseCom(brush);
                releaseCom(geometry);
                return false;
            }
            ctx()->FillGeometry(geometry, brush);
            releaseCom(brush);
            releaseCom(geometry);
        }
        return true;
    }

    bool ensureBlurSnapshot() {
        if (blur_snapshot_) return true;
        if (!backing_bitmap_ || pixel_width_ == 0 || pixel_height_ == 0) return false;
        const D2D1_BITMAP_PROPERTIES properties = D2D1::BitmapProperties(
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        return SUCCEEDED(ctx()->CreateBitmap(
            D2D1::SizeU(pixel_width_, pixel_height_), nullptr, 0, properties, &blur_snapshot_)) && blur_snapshot_;
    }

    /* Resume the backing target after a segment-ending backdrop blur.
     * Direct2D 1.0 has no effects graph, but its bitmaps and compatible
     * targets stay in the hardware resource domain: copy the current
     * backdrop on-GPU, approximate the box blur with a 5x5 separable-
     * Gaussian sample kernel into a temporary GPU target, then composite
     * that target over only the affected rect. There is no readback and
     * no full RGBA allocation/swizzle on the CPU. */
    Rect blurTarget(const Command &command, const Rect *outer_clip) const {
        Rect target = command.has_transform ? transformedRect(command.effect.rect, command.transform) : normalized(command.effect.rect);
        target = intersection(target, Rect{0, 0, static_cast<float>(surface_width_), static_cast<float>(surface_height_)});
        if (command.has_clip) target = intersection(target, command.clip);
        if (outer_clip) target = intersection(target, *outer_clip);
        return target;
    }

    bool resumeAndDrawBlur(const Command &command, Rect target) {
        auto resume = [&] {
            ctx()->BeginDraw();
            ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
        };

        /* The backing surface is now the context's bound target rather
         * than something to fetch back out of it, so the backdrop copy
         * reads it directly. */
        if (!backing_bitmap_ || !ensureBlurSnapshot() ||
            FAILED(blur_snapshot_->CopyFromBitmap(nullptr, backing_bitmap_, nullptr))) {
            resume();
            return false;
        }

        const float opacity = clamp01(command.opacity);

        const double pixel_width_value = std::ceil(target.width * scale_);
        const double pixel_height_value = std::ceil(target.height * scale_);
        if (pixel_width_value < 1 || pixel_height_value < 1 ||
            pixel_width_value > kMaxSurfacePixels || pixel_height_value > kMaxSurfacePixels) {
            resume();
            return false;
        }
        const D2D1_SIZE_F desired = D2D1::SizeF(target.width, target.height);
        const D2D1_SIZE_U pixels = D2D1::SizeU(
            static_cast<UINT32>(pixel_width_value), static_cast<UINT32>(pixel_height_value));
        const D2D1_PIXEL_FORMAT format = D2D1::PixelFormat(
            DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
        ID2D1BitmapRenderTarget *temporary = nullptr;
        ID2D1Bitmap *blurred = nullptr;
        HRESULT result = ctx()->CreateCompatibleRenderTarget(
            &desired, &pixels, &format, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE, &temporary);
        if (FAILED(result) || !temporary) {
            releaseCom(temporary);
            resume();
            return false;
        }
        temporary->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        temporary->BeginDraw();
        temporary->Clear(D2D1::ColorF(0, 0, 0, 0));
        /* D2D's target DPI applies the presentation scale, but this blur
         * bypasses the command transform after converting its rect to a
         * device-space bounding box. Scale the kernel explicitly so a
         * transformed blur keeps parity with the reference/AppKit paths. */
        const float radius = std::min(64.0f,
            std::max(0.0f, command.effect.blur * transformScale(command.transform)));
        const float offsets[5] = {-1.0f, -0.5f, 0.0f, 0.5f, 1.0f};
        const float weights[5] = {1.0f, 4.0f, 6.0f, 4.0f, 1.0f};
        ID2D1BitmapBrush *sample_brush = nullptr;
        const D2D1_BITMAP_BRUSH_PROPERTIES sample_properties = D2D1::BitmapBrushProperties(
            D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        result = temporary->CreateBitmapBrush(blur_snapshot_, &sample_properties, nullptr, &sample_brush);
        if (SUCCEEDED(result) && !sample_brush) result = E_FAIL;
        if (SUCCEEDED(result) && sample_brush) {
            float accumulated_weight = 0;
            for (size_t y = 0; y < 5; ++y) {
                for (size_t x = 0; x < 5; ++x) {
                    const float dx = offsets[x] * radius;
                    const float dy = offsets[y] * radius;
                    const float weight = weights[x] * weights[y];
                    accumulated_weight += weight;
                    /* Translate the whole-surface snapshot beneath the
                     * target-local output. The brush clamps each sample
                     * at a surface edge, so a full-surface blur keeps
                     * nonzero kernel offsets instead of collapsing every
                     * tap onto the unblurred source. */
                    sample_brush->SetOpacity(weight / accumulated_weight);
                    sample_brush->SetTransform(D2D1::Matrix3x2F::Translation(
                        -(target.x + dx), -(target.y + dy)));
                    temporary->FillRectangle(
                        D2D1::RectF(0, 0, target.width, target.height), sample_brush);
                }
            }
        }
        const HRESULT draw_result = temporary->EndDraw();
        if (SUCCEEDED(result)) result = draw_result;
        if (SUCCEEDED(result)) result = temporary->GetBitmap(&blurred);

        resume();
        if (SUCCEEDED(result) && blurred) {
            ctx()->PushAxisAlignedClip(d2dRect(target), D2D1_ANTIALIAS_MODE_ALIASED);
            ctx()->DrawBitmap(blurred, d2dRect(target), opacity,
                D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
            ctx()->PopAxisAlignedClip();
        }
        releaseCom(sample_brush);
        releaseCom(blurred);
        releaseCom(temporary);
        return SUCCEEDED(result);
    }

    bool drawCommandList(const std::vector<const Command *> &commands, const Rect *outer_clip) {
        for (const Command *command : commands) {
            if (command->kind == 13) {
                /* Cull before ending the current segment or copying the
                 * full backing bitmap. A localized blur outside a dirty
                 * patch must cost no more than any other culled command. */
                const Rect target = blurTarget(*command, outer_clip);
                if (empty(target) || command->effect.blur <= 0 || command->opacity <= 0) continue;
                const HRESULT segment = ctx()->EndDraw();
                if (FAILED(segment)) {
                    ctx()->BeginDraw();
                    return false;
                }
                if (!resumeAndDrawBlur(*command, target)) return false;
                continue;
            }
            if (!drawCommand(*command, outer_clip)) return false;
        }
        return true;
    }

    bool drawCommand(const Command &command, const Rect *outer_clip) {
        if (outer_clip && !intersects(command.bounds, *outer_clip)) return true;
        ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
        if (outer_clip) ctx()->PushAxisAlignedClip(d2dRect(*outer_clip), D2D1_ANTIALIAS_MODE_ALIASED);
        if (command.has_clip) ctx()->PushAxisAlignedClip(d2dRect(command.clip), D2D1_ANTIALIAS_MODE_ALIASED);
        if (command.has_transform) {
            const Affine &value = command.transform;
            ctx()->SetTransform(D2D1::Matrix3x2F(value.a, value.b, value.c, value.d, value.tx, value.ty));
        }
        bool ok = false;
        switch (command.kind) {
            case 0: case 1: case 2: case 3: case 8:
                ok = drawPaintedShape(command, false);
                break;
            case 4: case 5: case 6: case 7: case 9:
                ok = drawPaintedShape(command, true);
                break;
            case 10:
                ok = drawImage(command);
                break;
            case 11:
                ok = drawText(command);
                break;
            case 12:
                ok = drawShadow(command);
                break;
            default:
                ok = false;
                break;
        }
        ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
        if (command.has_clip) ctx()->PopAxisAlignedClip();
        if (outer_clip) ctx()->PopAxisAlignedClip();
        return ok;
    }

    bool commandsSupported(const std::vector<const Command *> &commands) const {
        for (const Command *command : commands) {
            if (!command || command->kind > 13) return false;
            if (command->kind <= 9 && (command->shape.kind == Shape::Kind::none || command->paint.kind == Paint::Kind::none)) return false;
            if (command->kind == 10 && command->image.id == 0) return false;
            if (command->kind == 12 && command->effect.kind != Effect::Kind::shadow) return false;
            if (command->kind == 13 && command->effect.kind != Effect::Kind::blur) return false;
        }
        return true;
    }

    bool applyImageActions(const DecodedPacket &packet) {
        auto next = image_cache_;
        for (const ImageAction &action : packet.image_actions) {
            if (action.kind == 2) next.erase(action.id);
            else if (!imageActionResolvesResource(action.kind)) return false;
        }
        for (const ImageAction &action : packet.image_actions) {
            if (!imageActionResolvesResource(action.kind)) continue;
            if (action.image_index == UINT32_MAX || action.image_index >= packet.images.size()) return false;
            const ImageMeta &meta = packet.images[action.image_index];
            if (meta.id != action.id || meta.id == 0) return false;
            std::shared_ptr<ImageResource> resource = renderer_->image(meta.id);
            if (!imageMetadataMatchesResource(
                    resource != nullptr,
                    meta.width,
                    meta.height,
                    resource ? resource->width : 0,
                    resource ? resource->height : 0)) return false;
            if (resource) next[meta.id] = std::move(resource);
            else next.erase(meta.id);
        }
        image_cache_ = std::move(next);
        /* The renderer-wide remove releases the shared pixels, but each
         * surface owns its own Direct2D bitmap. Any action that reconciles
         * an id to absent must drop that COM resource too so unregisters do
         * not leave stale texture memory behind. */
        for (const ImageAction &action : packet.image_actions) {
            if (image_cache_.find(action.id) == image_cache_.end()) {
                releaseImageBitmap(action.id);
            }
        }
        return true;
    }

    bool renderCommands(const std::vector<const Command *> &commands, const DecodedPacket &packet, Color clear, bool full_surface) {
        const GpuProfileSpan profile_span(gpuProfileActive(), &profile_render_ns_);
        beginOn(backing_bitmap_);
        bool ok = true;
        if (full_surface) {
            ctx()->Clear(d2dColor(clear));
            ok = drawCommandList(commands, nullptr);
        } else if (packet.has_scissor) {
            std::vector<Rect> regions = packet.dirty_rects;
            if (regions.empty()) regions.push_back(packet.scissor);
            ID2D1SolidColorBrush *clear_brush = nullptr;
            if (FAILED(ctx()->CreateSolidColorBrush(d2dColor(clear), &clear_brush))) ok = false;
            for (const Rect &source_region : regions) {
                if (!ok) break;
                Rect region = intersection(normalized(source_region), normalized(packet.scissor));
                region = intersection(region, Rect{0, 0, static_cast<float>(surface_width_), static_cast<float>(surface_height_)});
                if (empty(region)) continue;
                ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
                ctx()->PushAxisAlignedClip(d2dRect(region), D2D1_ANTIALIAS_MODE_ALIASED);
                /* Normal gpu_surface windows are opaque; source-over is
                 * therefore byte-equivalent to copy-clear here. Alpha
                 * top-level windows intentionally use the pixel path. */
                ctx()->FillRectangle(d2dRect(region), clear_brush);
                ctx()->SetTransform(D2D1::Matrix3x2F::Identity());
                ctx()->PopAxisAlignedClip();
                if (!drawCommandList(commands, &region)) { ok = false; break; }
            }
            releaseCom(clear_brush);
        } else {
            /* A load without a scissor intentionally overlays the
             * supplied command list without clearing retained pixels. */
            ok = drawCommandList(commands, nullptr);
        }
        const HRESULT end = endOn();
        if (!ok) return false;
        if (FAILED(end)) {
            handleDeviceLoss(end);
            return false;
        }
        /* No GetBitmap round trip any more: `backing_bitmap_` is the
         * target that was just drawn into, and it outlives this call. */
        content_valid_ = true;
        return true;
    }

    std::shared_ptr<GpuRendererImpl> renderer_;
    HWND hwnd_ = nullptr;
    /* Stable per-surface identity for the profile log. `seq` counts
     * presents PER SURFACE, so in an app with several gpu_surfaces (a
     * video editor has a dozen) sequence numbers collide across surfaces
     * and any reducer that groups by seq alone silently mixes them. */
    unsigned surface_id_ = 0;
    /* The retained content surface. Device-owned (not target-owned as the
     * old CreateCompatibleRenderTarget bitmap was), which is what lets the
     * image cache outlive a resize in the next phase. */
    ID2D1Bitmap1 *backing_bitmap_ = nullptr;
    /* Presentation: the flip-model swap chain and a D2D view of its back
     * buffer. CANNOT_DRAW because nothing ever samples from it -- it is
     * written once per paint and handed to the compositor. */
    IDXGISwapChain1 *swap_chain_ = nullptr;
    ID2D1Bitmap1 *swap_bitmap_ = nullptr;
    /* ALLOCATED buffer extent, on the granularity grid -- not the client
     * size. `source_*` is the client-sized region actually presented out
     * of it, and is what damage and dirty rects are measured against. */
    UINT swap_width_ = 0;
    UINT swap_height_ = 0;
    UINT source_width_ = 0;
    UINT source_height_ = 0;
    /* Surface scale the D2D view of buffer 0 was created at; a DPI change
     * has to rebuild it even when the buffers themselves are unchanged. */
    double swap_bitmap_scale_ = 0;
    Color swap_background_ = {};
    bool swap_background_applied_ = false;
    /* Buffer allocations (create + every ResizeBuffers) since launch.
     * Reported on the profile line, because "the grid is working" is not
     * observable from timings alone. */
    uint64_t swap_alloc_count_ = 0;
    /* Damage bookkeeping for the partial copy. `swap_last_damage_` is the
     * previous paint's damage; `swap_history_valid_` says the buffers hold
     * a known frame history at all (false right after create/resize/loss,
     * when their contents are undefined). See `paintRects`. */
    std::vector<RECT> swap_last_damage_;
    bool swap_history_valid_ = false;
    /* `NATIVE_SDK_GPU_FULL_PRESENT=1` pins every paint to the
     * full-surface copy and plain Present. It exists to A/B the partial
     * path against itself on one build and one workload, and to bisect a
     * suspected damage-tracking artifact without a rebuild. */
    const bool force_full_present_ = envFlagSet(L"NATIVE_SDK_GPU_FULL_PRESENT");
    const unsigned simulate_loss_after_ = envCount(L"NATIVE_SDK_GPU_SIMULATE_DEVICE_LOSS");
    unsigned paints_since_start_ = 0;
    /* 1x1 CPU-readable staging bitmap for `readColorAt`. Replaces the
     * GDI-interop read, which required the backing surface to be
     * GDI_COMPATIBLE -- a constraint a device-context target cannot
     * carry. See the comment there. */
    ID2D1Bitmap1 *readback_bitmap_ = nullptr;
    ID2D1Bitmap *blur_snapshot_ = nullptr;
    /* Renderer device generation these resources were built against. */
    uint64_t device_generation_ = 0;
    ID2D1StrokeStyle *rect_stroke_ = nullptr;
    ID2D1StrokeStyle *butt_stroke_ = nullptr;
    ID2D1StrokeStyle *round_stroke_ = nullptr;
    std::map<uint64_t, CachedBitmap> image_bitmaps_;
    std::map<uint64_t, std::shared_ptr<ImageResource>> image_cache_;
    std::map<uint64_t, Command> retained_commands_;
    std::vector<uint64_t> retained_order_;
    uint64_t retained_generation_ = 0;
    bool retained_valid_ = false;
    std::vector<Command> last_commands_;
    Color clear_color_ = {};
    double surface_width_ = 0;
    double surface_height_ = 0;
    double scale_ = 1;
    uint32_t pixel_width_ = 0;
    uint32_t pixel_height_ = 0;
    bool content_valid_ = false;

    /* `NATIVE_SDK_GPU_PROFILE` accumulators, reset per present. Untouched
     * and never read when the profiler is off (see `GpuProfileLog`). */
    uint64_t profile_sequence_ = 0;
    uint64_t profile_targets_ns_ = 0;
    uint64_t profile_image_ns_ = 0;
    uint64_t profile_render_ns_ = 0;
    uint64_t profile_image_bytes_ = 0;
    size_t profile_flushed_bitmaps_ = 0;
    uint32_t profile_image_uploads_ = 0;
    /* Present's own cost, split out of the paint span: with sync
     * interval 0 and a two-deep flip queue this is where the UI thread
     * waits for a free back buffer, and that wait is not copy work. */
    uint64_t profile_swap_present_ns_ = 0;
    size_t profile_swap_dirty_rects_ = 0;
    bool profile_swap_full_copy_ = false;
    uint64_t profile_swap_damage_px_ = 0;
    bool profile_swap_exact_ = false;
    bool profile_swap_history_ = false;
    bool profile_target_rebuild_ = false;
};

int GpuSurfaceImpl::present(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) {
    if (!gpuProfileActive()) return presentPacket(present, info);
    profile_sequence_ += 1;
    profile_targets_ns_ = 0;
    profile_image_ns_ = 0;
    profile_render_ns_ = 0;
    profile_image_bytes_ = 0;
    profile_flushed_bitmaps_ = 0;
    profile_image_uploads_ = 0;
    profile_target_rebuild_ = false;
    const uint64_t begin_ns = gpuClockNs();
    const int outcome = presentPacket(present, info);
    const uint64_t total_ns = gpuClockNs() - begin_ns;
    GpuProfileLog::shared().line(
        "present surface=%u seq=%llu outcome=%d pw=%u ph=%u rebuild=%d flushed=%llu targets_us=%llu "
        "images_us=%llu images_n=%u image_kib=%llu render_us=%llu decode_us=%llu total_us=%llu",
        surface_id_,
        static_cast<unsigned long long>(profile_sequence_),
        outcome,
        pixel_width_,
        pixel_height_,
        profile_target_rebuild_ ? 1 : 0,
        static_cast<unsigned long long>(profile_flushed_bitmaps_),
        static_cast<unsigned long long>(gpuProfileMicros(profile_targets_ns_)),
        static_cast<unsigned long long>(gpuProfileMicros(profile_image_ns_)),
        profile_image_uploads_,
        static_cast<unsigned long long>(profile_image_bytes_ / 1024),
        static_cast<unsigned long long>(gpuProfileMicros(profile_render_ns_)),
        static_cast<unsigned long long>(gpuProfileMicros(info ? info->decode_ns : 0)),
        static_cast<unsigned long long>(gpuProfileMicros(total_ns)));
    return outcome;
}

int GpuSurfaceImpl::presentPacket(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) {
    if (info) *info = {};
    /* A no-change packet is normally a cheap completion. After device
     * loss there is no retained bitmap to paint, though: decode the same
     * full-list payload and rebuild it. If the runtime first offers a
     * patch, retained_valid_ rejects it and the runtime resends a keyed
     * full packet in this frame. */
    if (!present.requires_render && content_valid_) return 1;
    if (!present.representable || present.unsupported_command_count != 0 ||
        !present.packet || present.packet_len == 0 || present.surface_width <= 0 || present.surface_height <= 0) return 0;

    const uint64_t decode_begin_ns = gpuClockNs();
    DecodedPacket packet;
    if (!decodePacket(present.packet, present.packet_len, &packet)) return 0;
    const uint64_t draw_begin_ns = gpuClockNs();
    const double scale = present.scale > 0 ? present.scale : 1.0;
    const double pixel_width_value = std::ceil(present.surface_width * scale);
    const double pixel_height_value = std::ceil(present.surface_height * scale);
    if (!std::isfinite(pixel_width_value) || !std::isfinite(pixel_height_value) ||
        pixel_width_value < 1 || pixel_height_value < 1 ||
        pixel_width_value > kMaxSurfacePixels || pixel_height_value > kMaxSurfacePixels) return 0;
    const uint32_t pixel_width = static_cast<uint32_t>(pixel_width_value);
    const uint32_t pixel_height = static_cast<uint32_t>(pixel_height_value);

    std::map<uint64_t, Command> next_retained;
    std::vector<uint64_t> next_order;
    std::vector<const Command *> draw_commands;
    const bool patch = packet.load_action == 3;
    if (patch) {
        if (!retained_valid_ || packet.generation == 0 || packet.generation != retained_generation_) return 0;
        next_retained = retained_commands_;
        for (uint64_t key : packet.evicts) {
            auto found = next_retained.find(key);
            if (found == next_retained.end()) {
                retained_valid_ = false;
                return 0;
            }
            next_retained.erase(found);
        }
        for (const KeyedCommand &upsert : packet.upserts) next_retained[upsert.key] = upsert.command;
        if (next_retained.size() > kRetainedCommandCap || packet.order.size() != next_retained.size()) {
            retained_valid_ = false;
            return 0;
        }
        std::set<uint64_t> seen;
        next_order.reserve(packet.order.size());
        draw_commands.reserve(packet.order.size());
        for (uint64_t key : packet.order) {
            auto found = next_retained.find(key);
            if (found == next_retained.end() || !seen.insert(key).second) {
                retained_valid_ = false;
                return 0;
            }
            next_order.push_back(key);
            draw_commands.push_back(&found->second);
        }
    } else {
        draw_commands.reserve(packet.commands.size());
        for (const KeyedCommand &keyed : packet.commands) draw_commands.push_back(&keyed.command);
    }
    if (present.command_count != 0 && present.command_count != draw_commands.size()) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    if (!commandsSupported(draw_commands)) return 0;

    const bool full_surface = packet.load_action == 2 || (patch && !packet.has_scissor);
    const bool same_backing = content_valid_ && pixel_width_ == pixel_width && pixel_height_ == pixel_height &&
        surface_width_ == present.surface_width && surface_height_ == present.surface_height && scale_ == scale;
    if (!full_surface && !same_backing) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    /* Before touching any GPU resource: a device removed since the last
     * frame leaves this surface holding a backing bitmap, a swap chain,
     * and a texture cache that all belong to it. `syncDevice` drops them
     * and adopts the rebuilt stack; a refused present here makes the
     * runtime resend a full packet, which is exactly the resync a fresh
     * device needs. */
    if (!syncDevice()) return 0;
    if (!ensureTargets(present.surface_width, present.surface_height, scale, pixel_width, pixel_height)) {
        releaseDeviceResources(true);
        return 0;
    }
    if (!full_surface && !content_valid_) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    if (!applyImageActions(packet)) {
        if (patch) retained_valid_ = false;
        return 0;
    }

    const Color clear = {
        static_cast<float>(present.clear_rgba[0]) / 255.0f,
        static_cast<float>(present.clear_rgba[1]) / 255.0f,
        static_cast<float>(present.clear_rgba[2]) / 255.0f,
        /* Direct2D child surfaces are the opaque path. Per-pixel-alpha
         * top-level windows are refused before this renderer and use the
         * exact layered pixel compositor, matching the GDI path's forced
         * opaque destination alpha here. */
        1.0f,
    };
    if (!renderCommands(draw_commands, packet, clear, full_surface)) {
        if (patch) retained_valid_ = false;
        return 0;
    }

    if (patch) {
        retained_commands_ = std::move(next_retained);
        retained_order_ = std::move(next_order);
        /* generation is unchanged */
    } else {
        bool retainable = packet.load_action == 2 && packet.generation != 0 &&
            packet.commands.size() <= kRetainedCommandCap;
        std::map<uint64_t, Command> retained;
        std::vector<uint64_t> order;
        if (retainable) {
            for (const KeyedCommand &keyed : packet.commands) {
                if (retained.find(keyed.key) != retained.end()) {
                    retainable = false;
                    break;
                }
                retained.emplace(keyed.key, keyed.command);
                order.push_back(keyed.key);
            }
        }
        if (retainable) {
            retained_commands_ = std::move(retained);
            retained_order_ = std::move(order);
            retained_generation_ = packet.generation;
            retained_valid_ = true;
        } else {
            retained_commands_.clear();
            retained_order_.clear();
            retained_generation_ = 0;
            retained_valid_ = false;
        }
    }

    last_commands_.clear();
    last_commands_.reserve(draw_commands.size());
    if (patch) {
        for (uint64_t key : retained_order_) last_commands_.push_back(retained_commands_.at(key));
    } else {
        for (const KeyedCommand &keyed : packet.commands) last_commands_.push_back(keyed.command);
    }
    clear_color_ = clear;

    if (info) {
        info->did_render = true;
        info->decode_ns = draw_begin_ns - decode_begin_ns;
        info->draw_ns = gpuClockNs() - draw_begin_ns;
        info->nonblank = clear.r != 0 || clear.g != 0 || clear.b != 0 || !last_commands_.empty();
        info->sample_color = representativeColorAt(present.surface_width * 0.5, present.surface_height * 0.5);
        if (!full_surface && packet.has_scissor) {
            const Rect surface = {0, 0, static_cast<float>(present.surface_width), static_cast<float>(present.surface_height)};
            const Rect scissor = intersection(normalized(packet.scissor), surface);
            const std::vector<Rect> &regions = packet.dirty_rects;
            auto append_dirty = [&](Rect dirty) {
                dirty = intersection(normalized(dirty), scissor);
                if (empty(dirty) || info->dirty_rect_count >= kWindowsGpuDirtyRectCap) return;
                RECT &pixels = info->dirty_rects[info->dirty_rect_count];
                pixels.left = std::max<LONG>(0, static_cast<LONG>(std::floor(dirty.x * scale)));
                pixels.top = std::max<LONG>(0, static_cast<LONG>(std::floor(dirty.y * scale)));
                pixels.right = std::min<LONG>(static_cast<LONG>(pixel_width), static_cast<LONG>(std::ceil((dirty.x + dirty.width) * scale)));
                pixels.bottom = std::min<LONG>(static_cast<LONG>(pixel_height), static_cast<LONG>(std::ceil((dirty.y + dirty.height) * scale)));
                if (pixels.right > pixels.left && pixels.bottom > pixels.top) info->dirty_rect_count += 1;
            };
            if (regions.empty()) append_dirty(scissor);
            else for (Rect dirty : regions) append_dirty(dirty);
        }
    }
    return 1;
}

bool GpuSurfaceImpl::paint(const RECT *paint_rects, size_t paint_rect_count) {
    if (!gpuProfileActive()) return paintRects(paint_rects, paint_rect_count);
    /* `content` and `rects` together separate a real blit from the two
     * shapes that return in nanoseconds without drawing: no retained
     * bitmap yet, and an empty update region. Both report ok=1, so without
     * these a reducer averages them in and understates the copy. */
    const bool had_content = content_valid_ && backing_bitmap_ != nullptr;
    profile_swap_present_ns_ = 0;
    profile_swap_dirty_rects_ = 0;
    profile_swap_damage_px_ = 0;
    profile_swap_full_copy_ = false;
    const uint64_t begin_ns = gpuClockNs();
    const bool ok = paintRects(paint_rects, paint_rect_count);
    const uint64_t blit_ns = gpuClockNs() - begin_ns;
    GpuProfileLog::shared().line(
        "paint surface=%u seq=%llu ok=%d content=%d pw=%u ph=%u rects=%llu blit_us=%llu present_us=%llu "
        "full=%d dirty=%llu dmg_px=%llu exact=%d hist=%d sw=%u sh=%u aw=%u ah=%u allocs=%llu",
        surface_id_,
        static_cast<unsigned long long>(profile_sequence_),
        ok ? 1 : 0,
        had_content ? 1 : 0,
        pixel_width_,
        pixel_height_,
        static_cast<unsigned long long>(paint_rect_count),
        static_cast<unsigned long long>(gpuProfileMicros(blit_ns)),
        static_cast<unsigned long long>(gpuProfileMicros(profile_swap_present_ns_)),
        profile_swap_full_copy_ ? 1 : 0,
        static_cast<unsigned long long>(profile_swap_dirty_rects_),
        static_cast<unsigned long long>(profile_swap_damage_px_),
        profile_swap_exact_ ? 1 : 0,
        profile_swap_history_ ? 1 : 0,
        /* sw/sh stay the PRESENTED extent -- the damage-coverage
         * denominator every reducer already divides by. aw/ah are the
         * allocation behind it, and `allocs` counts the buffer
         * reallocations this surface has paid for since launch: the one
         * number that says whether the granularity grid is working. */
        source_width_,
        source_height_,
        swap_width_,
        swap_height_,
        static_cast<unsigned long long>(swap_alloc_count_));
    return ok;
}

bool GpuSurfaceImpl::paintRects(const RECT *paint_rects, size_t paint_rect_count) {
    if (!syncDevice()) return false;
    if (!content_valid_ || !backing_bitmap_) return true;
    if (paint_rect_count > 0 && paint_rects == nullptr) return false;
    RECT client = {};
    if (!hwnd_ || !GetClientRect(hwnd_, &client)) return false;
    const UINT client_width = static_cast<UINT>(std::max<LONG>(1, client.right - client.left));
    const UINT client_height = static_cast<UINT>(std::max<LONG>(1, client.bottom - client.top));
    if (!ensureSwapChain(client_width, client_height)) {
        releaseDeviceResources(true);
        return false;
    }
    if (simulate_loss_after_ > 0 && ++paints_since_start_ == simulate_loss_after_) {
        /* NATIVE_SDK_GPU_SIMULATE_DEVICE_LOSS=<n>: take the recovery path
         * on the nth paint. Disabling an adapter mid-drag is the honest
         * test but not a repeatable one, and this exercises the same
         * code -- rebuild the stack, drop every surface's resources,
         * force a full resync -- on demand. */
        handleDeviceLoss(DXGI_ERROR_DEVICE_REMOVED);
        return false;
    }

    /* `WM_PAINT` remains the presentation trigger (the plan's option (a)):
     * the host still invalidates and Windows still decides when to paint;
     * this call ends in Present instead of a blt through the DWM
     * redirection surface. Moving presentation into `present()` --
     * option (b) -- is a separate, deliberate change.
     *
     * How much gets copied is the interesting part.
     *
     * Under the blt model `paint()` clipped the copy to the update
     * region, because the redirection surface persisted and untouched
     * pixels were already last frame's. A flip-model back buffer does not
     * persist: with `BufferCount = 2` the buffer about to be drawn is the
     * one presented TWO frames ago. So the region that must be refreshed
     * is not this paint's damage alone, it is
     *
     *     damage(this paint) UNION damage(previous paint)
     *
     * -- everything that has changed since the pixels currently sitting
     * in this buffer were correct. Copy that and the whole buffer equals
     * the current frame again, which is exactly the precondition
     * `Present1` states before it will honour dirty rects. The dirty
     * rects themselves are this paint's damage alone, because they
     * describe the delta against the PREVIOUSLY PRESENTED frame.
     *
     * `swap_history_valid_` is the guard: right after a create, a
     * `ResizeBuffers`, or a device loss the buffers hold undefined
     * pixels, no history exists, and the copy has to be full.
     *
     * (`CopyFromBitmap` would be the cheaper primitive for the full case
     * but is unavailable: it requires identical D2D pixel formats, and
     * the backing surface is PREMULTIPLIED while a flip-model HWND swap
     * chain's D2D view must be ALPHA_MODE_IGNORE -- E_INVALIDARG on that
     * pair. Aligning the backing surface to IGNORE would change the blend
     * semantics every layer and opacity group renders under, which is not
     * a trade worth making for a presentation change.) */
    applyBackgroundColor();

    /* Against the PRESENTED region, not the allocation. The buffers are
     * rounded up to the granularity grid, so their pixel size says nothing
     * about whether the backing surface and the window agree -- and a
     * dirty rect outside the source region is not a valid dirty rect. */
    const D2D1_SIZE_U backing_pixels = backing_bitmap_->GetPixelSize();
    const bool exact = backing_pixels.width == source_width_ && backing_pixels.height == source_height_;

    std::vector<RECT> damage;
    damage.reserve(paint_rect_count);
    for (size_t index = 0; index < paint_rect_count; ++index) {
        RECT clamped = paint_rects[index];
        clamped.left = std::max<LONG>(0, clamped.left);
        clamped.top = std::max<LONG>(0, clamped.top);
        clamped.right = std::min<LONG>(static_cast<LONG>(source_width_), clamped.right);
        clamped.bottom = std::min<LONG>(static_cast<LONG>(source_height_), clamped.bottom);
        if (clamped.right > clamped.left && clamped.bottom > clamped.top) damage.push_back(clamped);
    }
    /* An empty update region is nothing to show. Presenting anyway would
     * flip a buffer holding a two-frames-old image to the front. */
    if (damage.empty()) return true;

    const float logical_client_width = static_cast<float>(client_width / scale_);
    const float logical_client_height = static_cast<float>(client_height / scale_);

    /* Where the retained image lands. Deliberately NOT the client rect.
     *
     * Between a resize step and the packet that re-renders at the new
     * size, `backing_bitmap_` still holds the PREVIOUS size's pixels.
     * Drawing those into the new client rect stretches a whole surface's
     * image to a size the app never laid out, and every anchored thing
     * inside it slides and distorts for as long as the drag runs: a menu
     * bar pulls away from its own left edge, a right-flush caption
     * cluster smears, glyphs resample a fraction of a pixel on every
     * step. The window's contents read as rubber.
     *
     * Anchored at the top-left and drawn at the size it was rendered,
     * every retained pixel stays where the app put it. The only wrong
     * region is then the strip the window has just gained, and that is
     * cleared below. A stale POSITION for one frame is invisible; a
     * stale SHAPE is not.
     *
     * A sub-pixel disagreement is not staleness and must keep scaling.
     * The backing surface is sized from the packet
     * (`ceil(logical * scale)`) and the swap chain from `GetClientRect`,
     * so at fractional DPI the two differ by a pixel indefinitely --
     * 1349x895 against 1348x894 at 125%. Anchoring that would leave a
     * permanent hairline of cleared pixels down two edges. */
    const auto pixel_delta = [](UINT a, UINT b) { return a > b ? a - b : b - a; };
    const UINT delta_width = pixel_delta(backing_pixels.width, source_width_);
    const UINT delta_height = pixel_delta(backing_pixels.height, source_height_);
    const float content_width = delta_width <= 1
        ? logical_client_width
        : static_cast<float>(backing_pixels.width / scale_);
    const float content_height = delta_height <= 1
        ? logical_client_height
        : static_cast<float>(backing_pixels.height / scale_);
    const D2D1_RECT_F whole = D2D1::RectF(0, 0, content_width, content_height);
    /* Exactly the one-pixel case resamples: zero already matches the
     * window, and anything larger is drawn at its own extent. Each axis
     * decides for itself -- a band whose width is a resize behind and
     * whose height is one DPI-rounded pixel off is the common shape. */
    const D2D1_INTERPOLATION_MODE sampling = (delta_width == 1 || delta_height == 1)
        ? D2D1_INTERPOLATION_MODE_LINEAR
        : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
    /* A window that grew leaves the retained image short of its own
     * client rect. Those pixels are not background: a flip-model back
     * buffer holds the frame presented two flips ago. */
    const bool uncovered = content_width < logical_client_width || content_height < logical_client_height;

    /* `full_copy` stays NOT gated on `exact`: treating the fractional-DPI
     * pixel above as a reason to copy everything meant the partial path
     * essentially never ran, and a partial copy is just as correct when
     * the blit scales -- it draws the same scaled image the full copy
     * would, clipped to the damage.
     *
     * An uncovered strip IS a reason. It has to be repainted on every
     * flip until the app renders at the new size, and it lies outside
     * this paint's damage, so a partial copy would present it stale. */
    const bool full_copy = force_full_present_ || !swap_history_valid_ || uncovered ||
        damage.size() + swap_last_damage_.size() > kSwapDirtyRectCap;

    beginOn(swap_bitmap_);
    if (full_copy) {
        if (uncovered) {
            /* The clear colour is by construction the colour that strip
             * is about to be painted -- the same reasoning
             * `applyBackgroundColor` runs on, and the same opaque
             * treatment, the swap chain's D2D view being ALPHA_MODE_IGNORE. */
            const D2D1_COLOR_F fill = D2D1::ColorF(
                clamp01(clear_color_.r), clamp01(clear_color_.g), clamp01(clear_color_.b), 1.0f);
            const auto clear_strip = [&](const D2D1_RECT_F &strip) {
                if (strip.right <= strip.left || strip.bottom <= strip.top) return;
                ctx()->PushAxisAlignedClip(strip, D2D1_ANTIALIAS_MODE_ALIASED);
                ctx()->Clear(fill);
                ctx()->PopAxisAlignedClip();
            };
            clear_strip(D2D1::RectF(content_width, 0, logical_client_width, logical_client_height));
            clear_strip(D2D1::RectF(0, content_height, content_width, logical_client_height));
        }
        ctx()->DrawBitmap(backing_bitmap_, whole, 1.0f, sampling, nullptr, nullptr);
    } else {
        auto copy_region = [&](const RECT &pixels) {
            /* Device pixels to logical, outset by one pixel each way so
             * the fractional-scale rounding can never leave a seam of
             * two-frames-old content along a damage edge. */
            const D2D1_RECT_F clip = D2D1::RectF(
                static_cast<float>((pixels.left - 1) / scale_),
                static_cast<float>((pixels.top - 1) / scale_),
                static_cast<float>((pixels.right + 1) / scale_),
                static_cast<float>((pixels.bottom + 1) / scale_));
            ctx()->PushAxisAlignedClip(clip, D2D1_ANTIALIAS_MODE_ALIASED);
            ctx()->DrawBitmap(backing_bitmap_, whole, 1.0f, sampling, nullptr, nullptr);
            ctx()->PopAxisAlignedClip();
        };
        for (const RECT &region : damage) copy_region(region);
        for (const RECT &region : swap_last_damage_) copy_region(region);
    }
    const HRESULT drawn = endOn();
    if (drawn == D2DERR_RECREATE_TARGET || FAILED(drawn)) {
        if (gpuProfileActive()) {
            GpuProfileLog::shared().line("paint-fail stage=copy hr=0x%08x bw=%u bh=%u sw=%u sh=%u aw=%u ah=%u",
                static_cast<unsigned>(drawn), backing_pixels.width, backing_pixels.height,
                source_width_, source_height_, swap_width_, swap_height_);
        }
        handleDeviceLoss(drawn);
        return false;
    }

    /* Sync interval 0: the host already paces frames against the
     * monitor's refresh, and blocking the UI thread inside Present would
     * put that pacing behind DXGI's. */
    const uint64_t present_begin_ns = gpuProfileActive() ? gpuClockNs() : 0;
    HRESULT presented = S_OK;
    if (full_copy) {
        presented = swap_chain_->Present(0, 0);
    } else {
        DXGI_PRESENT_PARAMETERS parameters = {};
        parameters.DirtyRectsCount = static_cast<UINT>(damage.size());
        parameters.pDirtyRects = damage.data();
        presented = swap_chain_->Present1(0, 0, &parameters);
    }
    if (gpuProfileActive()) {
        profile_swap_present_ns_ = gpuClockNs() - present_begin_ns;
        profile_swap_full_copy_ = full_copy;
        profile_swap_dirty_rects_ = full_copy ? 0 : damage.size();
        profile_swap_exact_ = exact;
        profile_swap_history_ = swap_history_valid_;
        /* Damage coverage is what decides whether the partial path can
         * ever help this app: a workload that invalidates its whole
         * surface every frame has nothing for dirty rects to save, and
         * without this field that looks identical to a broken
         * optimization. Counted over the copied union, not just this
         * paint's rects, because that is the work actually done. */
        profile_swap_damage_px_ = 0;
        for (const RECT &region : damage) {
            profile_swap_damage_px_ += static_cast<uint64_t>(region.right - region.left) *
                static_cast<uint64_t>(region.bottom - region.top);
        }
        if (!full_copy) {
            for (const RECT &region : swap_last_damage_) {
                profile_swap_damage_px_ += static_cast<uint64_t>(region.right - region.left) *
                    static_cast<uint64_t>(region.bottom - region.top);
            }
        }
    }
    if (presented == DXGI_STATUS_OCCLUDED) {
        /* Ground truth that the window is hidden. Not a failure, and
         * deliberately not wired into the existing occluded-pacing
         * heuristics -- that interacts with frame scheduling and is a
         * separate change.
         *
         * The buffers did not rotate, so the damage history did not
         * advance either; leave it alone. */
        return true;
    }
    if (FAILED(presented)) {
        if (gpuProfileActive()) {
            GpuProfileLog::shared().line("paint-fail stage=present hr=0x%08x", static_cast<unsigned>(presented));
        }
        handleDeviceLoss(presented);
        return false;
    }
    swap_last_damage_ = std::move(damage);
    swap_history_valid_ = true;
    return true;
}

/* Hidden-titlebar caption sampling, and its only caller.
 *
 * This used to run through `ID2D1GdiInteropRenderTarget::GetDC` +
 * `GetPixel`, which is why the backing surface carried
 * `D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_GDI_COMPATIBLE`. A
 * device-context target cannot carry that flag, so the read is now a
 * D2D1.1 CPU-readable staging bitmap: copy the one pixel, map it, read
 * BGRA. Same single-pixel synchronization point, no GDI, and the
 * GDI_COMPATIBLE constraint is gone from the whole renderer.
 *
 * (The migration plan scheduled this as Phase 5. It cannot be deferred:
 * the flag it removes lives on the `CreateCompatibleRenderTarget` call
 * that Phase 2 deletes.) */
bool GpuSurfaceImpl::readColorAt(double logical_x, double logical_y, uint32_t *color) {
    if (!color || !content_valid_ || !backing_bitmap_ || !(scale_ > 0) ||
        !std::isfinite(logical_x) || !std::isfinite(logical_y)) return false;
    const double pixel_x_value = std::floor(logical_x * scale_);
    const double pixel_y_value = std::floor(logical_y * scale_);
    if (pixel_x_value < 0 || pixel_y_value < 0 ||
        pixel_x_value >= pixel_width_ || pixel_y_value >= pixel_height_) return false;

    if (!readback_bitmap_) {
        const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
        if (FAILED(ctx()->CreateBitmap(D2D1::SizeU(1, 1), nullptr, 0, properties, &readback_bitmap_)) ||
            !readback_bitmap_) {
            releaseCom(readback_bitmap_);
            return false;
        }
    }

    const D2D1_POINT_2U destination = D2D1::Point2U(0, 0);
    const D2D1_RECT_U source = D2D1::RectU(
        static_cast<UINT32>(pixel_x_value), static_cast<UINT32>(pixel_y_value),
        static_cast<UINT32>(pixel_x_value) + 1, static_cast<UINT32>(pixel_y_value) + 1);
    if (FAILED(readback_bitmap_->CopyFromBitmap(&destination, backing_bitmap_, &source))) return false;

    D2D1_MAPPED_RECT mapped = {};
    const HRESULT map_result = readback_bitmap_->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (gpuProfileActive()) {
        /* The caller silently falls back to the retained-command colour
         * estimate when this returns false, so without a line here a
         * broken readback looks exactly like a working one. */
        GpuProfileLog::shared().line("readback seq=%llu hr=0x%08x x=%d y=%d",
            static_cast<unsigned long long>(profile_sequence_), static_cast<unsigned>(map_result),
            static_cast<int>(pixel_x_value), static_cast<int>(pixel_y_value));
    }
    if (FAILED(map_result) || !mapped.bits) return false;
    const uint8_t blue = mapped.bits[0];
    const uint8_t green = mapped.bits[1];
    const uint8_t red = mapped.bits[2];
    const HRESULT unmapped = readback_bitmap_->Unmap();
    if (FAILED(unmapped)) return false;
    /* The caller wants an opaque caption colour; the backing surface is
     * opaque by construction, so the source alpha carries no information
     * and premultiplication is a no-op. */
    *color = 0xff000000u |
        (static_cast<uint32_t>(red) << 16) |
        (static_cast<uint32_t>(green) << 8) |
        static_cast<uint32_t>(blue);
    return true;
}

uint32_t GpuSurfaceImpl::representativeColorAt(double logical_x, double logical_y) const {
    Color result = clear_color_;
    for (const Command &command : last_commands_) {
        if (!contains(command.bounds, logical_x, logical_y) || command.opacity <= 0) continue;
        const bool solid_fill = (command.kind == 0 || command.kind == 2 || command.kind == 8) &&
            command.paint.kind == Paint::Kind::color;
        if (!solid_fill) continue;
        const Color source = command.paint.color;
        const float alpha = clamp01(source.a * command.opacity);
        result.r = source.r * alpha + result.r * (1.0f - alpha);
        result.g = source.g * alpha + result.g * (1.0f - alpha);
        result.b = source.b * alpha + result.b * (1.0f - alpha);
        result.a = alpha + result.a * (1.0f - alpha);
    }
    return packedColor(result);
}

std::shared_ptr<WindowsGpuSurface> GpuRendererImpl::createSurface(HWND hwnd) {
    if (!hwnd) return nullptr;
    return std::make_shared<GpuSurfaceImpl>(shared_from_this(), hwnd);
}

} // namespace

std::shared_ptr<WindowsGpuRenderer> createWindowsGpuRenderer() {
    auto renderer = std::make_shared<GpuRendererImpl>();
    if (!renderer->initialize()) return nullptr;
    return renderer;
}
