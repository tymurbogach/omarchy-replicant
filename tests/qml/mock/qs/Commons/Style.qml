import QtQuick

// Minimal mock of the Omarchy Style singleton for container tests.
// The real module ships with Omarchy; this mock provides only the spacing
// values that the panel reads at load time.
QtObject {
  property var spacing: ({ "controlPaddingY": 8, "rowPadding": 12 })
}
