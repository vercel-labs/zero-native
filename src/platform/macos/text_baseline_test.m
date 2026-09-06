#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#include <stdint.h>
#include <stdlib.h>

#include "appkit_text_baseline.h"

typedef struct {
    int first;
    int last;
    CGFloat baselineOffset;
} NativeSdkTestInkRows;

static NSFont *NativeSdkTestFont(const uint8_t *bytes, size_t length, CGFloat size) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)data);
    if (!descriptor) return nil;
    CTFontRef coreTextFont = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CFRelease(descriptor);
    return CFBridgingRelease(coreTextFont);
}

static NativeSdkTestInkRows NativeSdkTestDrawText(
    NSFont *font,
    CGFloat size,
    CGFloat baseline,
    BOOL corrected,
    CGFloat lineHeight,
    NSString *value,
    size_t scanColumnLimit
) {
    const size_t width = 96;
    const size_t height = 72;
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = calloc(height, bytesPerRow);
    if (!pixels) return (NativeSdkTestInkRows){ .first = -1, .last = -1, .baselineOffset = NAN };
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return (NativeSdkTestInkRows){ .first = -1, .last = -1, .baselineOffset = NAN };
    }

    /* Match appkit_host.m's packet bitmap and flipped NSGraphicsContext. */
    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetShouldAntialias(context, true);
    CGContextTranslateCTM(context, 0, (CGFloat)height);
    CGContextScaleCTM(context, 1, -1);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];

    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: NSColor.whiteColor,
    } mutableCopy];
    CGFloat baselineOffset = size;
    if (lineHeight > 0) {
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.minimumLineHeight = lineHeight;
        paragraph.maximumLineHeight = lineHeight;
        attributes[NSParagraphStyleAttributeName] = paragraph;
        if (corrected) {
            NativeSdkAppKitDrawAttributedText(
                value,
                attributes,
                8,
                baseline,
                80,
                CGFLOAT_MAX,
                &baselineOffset
            );
        } else {
            [value drawWithRect:NSMakeRect(8, baseline - baselineOffset, 80, 30)
                        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                     attributes:attributes];
        }
    } else if (corrected) {
        NativeSdkAppKitDrawAttributedText(
            value,
            attributes,
            8,
            baseline,
            CGFLOAT_MAX,
            CGFLOAT_MAX,
            &baselineOffset
        );
    } else {
        [value drawAtPoint:NSMakePoint(8, baseline - size) withAttributes:attributes];
    }

    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(context);

    NativeSdkTestInkRows rows = { .first = -1, .last = -1, .baselineOffset = baselineOffset };
    const size_t scanColumns = MIN(width, scanColumnLimit);
    for (size_t row = 0; row < height; row++) {
        BOOL hasInk = NO;
        for (size_t column = 0; column < scanColumns; column++) {
            if (pixels[row * bytesPerRow + column * 4 + 3] != 0) {
                hasInk = YES;
                break;
            }
        }
        if (!hasInk) continue;
        if (rows.first < 0) rows.first = (int)row;
        rows.last = (int)row;
    }
    free(pixels);
    return rows;
}

/* Test-only AppKit pixel probe linked by build.zig, not by apps. The bundled
 * Geist fixtures have the same cap height but different vertical metrics at
 * 14.5pt, making them a hermetic regression for mixed-face baselines. */
int native_sdk_test_appkit_text_baselines(
    const uint8_t *regularBytes,
    size_t regularLength,
    const uint8_t *monoBytes,
    size_t monoLength,
    double size,
    double baseline,
    double *outRegularOffset,
    double *outMonoOffset,
    double *outCompactRegularOffset,
    double *outCompactMonoOffset,
    int *outOldRegularFirst,
    int *outOldMonoFirst,
    int *outFixedRegularFirst,
    int *outFixedMonoFirst,
    int *outWrappedRegularFirst,
    int *outWrappedMonoFirst,
    int *outCompactRegularFirst,
    int *outCompactMonoFirst,
    int *outFallbackFirst
) {
    @autoreleasepool {
        NSFont *regular = NativeSdkTestFont(regularBytes, regularLength, size);
        NSFont *mono = NativeSdkTestFont(monoBytes, monoLength, size);
        if (!regular || !mono) return 0;

        const NativeSdkTestInkRows oldRegular = NativeSdkTestDrawText(regular, size, baseline, NO, 0, @"H", 96);
        const NativeSdkTestInkRows oldMono = NativeSdkTestDrawText(mono, size, baseline, NO, 0, @"H", 96);
        const NativeSdkTestInkRows fixedRegular = NativeSdkTestDrawText(regular, size, baseline, YES, 0, @"H", 96);
        const NativeSdkTestInkRows fixedMono = NativeSdkTestDrawText(mono, size, baseline, YES, 0, @"H", 96);
        const NativeSdkTestInkRows wrappedRegular = NativeSdkTestDrawText(regular, size, baseline, YES, 20, @"H", 96);
        const NativeSdkTestInkRows wrappedMono = NativeSdkTestDrawText(mono, size, baseline, YES, 20, @"H", 96);
        /* Smaller than either face's font box: TextKit's valid first-baseline
         * offsets are negative, exercising the compact-line regression. */
        const NativeSdkTestInkRows compactRegular = NativeSdkTestDrawText(regular, size, baseline, YES, 1, @"H", 96);
        const NativeSdkTestInkRows compactMono = NativeSdkTestDrawText(mono, size, baseline, YES, 1, @"H", 96);
        /* The emoji resolves to a fallback face with taller metrics. Scan only
         * the leading Geist H to prove the shared TextKit draw keeps it on the
         * same baseline as the no-fallback direct path. */
        const NativeSdkTestInkRows fallback = NativeSdkTestDrawText(regular, size, baseline, YES, 20, @"H\U0001F600", 19);

        if (outRegularOffset) *outRegularOffset = round(regular.ascender);
        if (outMonoOffset) *outMonoOffset = round(mono.ascender);
        if (outCompactRegularOffset) *outCompactRegularOffset = compactRegular.baselineOffset;
        if (outCompactMonoOffset) *outCompactMonoOffset = compactMono.baselineOffset;
        if (outOldRegularFirst) *outOldRegularFirst = oldRegular.first;
        if (outOldMonoFirst) *outOldMonoFirst = oldMono.first;
        if (outFixedRegularFirst) *outFixedRegularFirst = fixedRegular.first;
        if (outFixedMonoFirst) *outFixedMonoFirst = fixedMono.first;
        if (outWrappedRegularFirst) *outWrappedRegularFirst = wrappedRegular.first;
        if (outWrappedMonoFirst) *outWrappedMonoFirst = wrappedMono.first;
        if (outCompactRegularFirst) *outCompactRegularFirst = compactRegular.first;
        if (outCompactMonoFirst) *outCompactMonoFirst = compactMono.first;
        if (outFallbackFirst) *outFallbackFirst = fallback.first;

        return oldRegular.first >= 0 && oldMono.first >= 0 && oldRegular.first != oldMono.first &&
            fixedRegular.first == fixedMono.first && fixedRegular.last == fixedMono.last &&
            wrappedRegular.first == wrappedMono.first && wrappedRegular.last == wrappedMono.last &&
            fixedRegular.first == wrappedRegular.first && fixedRegular.last == wrappedRegular.last &&
            compactRegular.baselineOffset < 0 && compactMono.baselineOffset < 0 &&
            compactRegular.first == compactMono.first && compactRegular.last == compactMono.last &&
            fixedRegular.first == compactRegular.first && fixedRegular.last == compactRegular.last &&
            fixedRegular.first == fallback.first && fixedRegular.last == fallback.last;
    }
}
