import QtQuick

// User-clone port of PontuArch's centered 36px icon tile. Keep one historical
// nominal size and font; only shrink a glyph if its measured ink exceeds the
// tile, then center the painted bounds on both axes (TextMetrics alone does
// not center JetBrains Mono's asymmetric line box).
Item {
  id: root

  property string text: ""
  property string fontFamily: "JetBrainsMono Nerd Font"
  property color color: "white"
  property real opticalCanvas: 36
  property real maxInkExtent: 36
  property real nominalFontSize: 20

  readonly property real nominalInkExtent: Math.max(
    nominalMetrics.tightBoundingRect.width,
    nominalMetrics.tightBoundingRect.height
  )
  readonly property real fittedFontSize: nominalInkExtent > root.maxInkExtent
    ? root.nominalFontSize * root.maxInkExtent / nominalInkExtent
    : root.nominalFontSize
  readonly property rect paintedBounds: Qt.rect(
    glyph.x + inkMetrics.tightBoundingRect.x,
    glyph.y + glyph.baselineOffset + inkMetrics.tightBoundingRect.y,
    inkMetrics.tightBoundingRect.width,
    inkMetrics.tightBoundingRect.height
  )
  readonly property real paintedCenterErrorX: paintedBounds.x + paintedBounds.width / 2 - width / 2
  readonly property real paintedCenterErrorY: paintedBounds.y + paintedBounds.height / 2 - height / 2
  readonly property real paintedWidth: paintedBounds.width
  readonly property real paintedHeight: paintedBounds.height
  readonly property real renderedFontSize: glyph.font.pixelSize

  implicitWidth: opticalCanvas
  implicitHeight: opticalCanvas

  TextMetrics {
    id: nominalMetrics
    font.family: root.fontFamily
    font.pixelSize: root.nominalFontSize
    text: root.text
  }

  TextMetrics {
    id: inkMetrics
    font.family: root.fontFamily
    font.pixelSize: root.fittedFontSize
    text: root.text
  }

  Text {
    id: glyph
    textFormat: Text.PlainText
    text: root.text
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.fittedFontSize
    renderType: Text.NativeRendering
    x: root.width / 2 - (inkMetrics.tightBoundingRect.x + inkMetrics.tightBoundingRect.width / 2)
    y: root.height / 2 - (baselineOffset + inkMetrics.tightBoundingRect.y + inkMetrics.tightBoundingRect.height / 2)
  }
}
