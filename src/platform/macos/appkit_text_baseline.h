#ifndef NATIVE_SDK_APPKIT_TEXT_BASELINE_H
#define NATIVE_SDK_APPKIT_TEXT_BASELINE_H

#import <AppKit/AppKit.h>

/* Shared by the packet host and its pixel regression. TextKit owns both the
 * fallback-face metrics and explicit-line-height placement, so build and draw
 * one layout and translate its first baseline to the engine coordinate. The
 * optional offset exposes that exact placement to the regression without
 * giving the test a second rendering algorithm that can drift from the host. */
static inline BOOL NativeSdkAppKitDrawAttributedText(
    NSString *value,
    NSDictionary *attributes,
    CGFloat x,
    CGFloat baseline,
    CGFloat width,
    CGFloat height,
    CGFloat *outFirstLineOffset
) {
    if (outFirstLineOffset) *outFirstLineOffset = 0;
    if (value.length == 0) return YES;

    NSTextStorage *storage = [[NSTextStorage alloc] initWithString:value attributes:attributes];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(
        width > 0 ? width : CGFLOAT_MAX,
        height > 0 ? height : CGFLOAT_MAX
    )];
    container.lineFragmentPadding = 0;
    [layoutManager addTextContainer:container];
    [storage addLayoutManager:layoutManager];
    [layoutManager ensureLayoutForTextContainer:container];

    NSRange glyphRange = [layoutManager glyphRangeForTextContainer:container];
    if (glyphRange.length == 0) return YES;
    CGFloat firstLineOffset = [layoutManager locationForGlyphAtIndex:glyphRange.location].y;
    if (outFirstLineOffset) *outFirstLineOffset = firstLineOffset;
    [layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:NSMakePoint(x, baseline - firstLineOffset)];
    return YES;
}

#endif
