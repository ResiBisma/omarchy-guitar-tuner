import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Live guitar tuner bar widget.
// Runs tuner.py (mic -> pitch detection) and shows the nearest string as a
// compact icon. Left click toggles listening; right click opens settings.
// Settings (tuning preset, reference pitch, in-tune threshold, mic
// sensitivity, auto-stop, display mode) persist to shell.json.
BarWidget {
  id: root
  moduleName: "icung.guitar-tuner"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color card: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)
  readonly property color inTune: Qt.rgba(0.45, 0.83, 0.5, 1)     // green
  readonly property color closeColor: Qt.rgba(0.93, 0.83, 0.35, 1)    // yellow
  readonly property color off: Qt.rgba(0.93, 0.42, 0.42, 1)      // red
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property string iconGlyph: "\ue1b8"                   // graphic_eq (Material Symbols)

  property bool popupOpen: false
  property bool settingsMode: false
  property var draftSettings: ({})
  property string settingsStatusText: ""

  property bool listening: false
  property string note: ""
  property real cents: 0
  property real freq: 0
  property var stringTable: []
  property var history: []

  // ---- settings helpers -----------------------------------------------------

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function cloneObject(value, fallback) {
    if (value === undefined || value === null) return fallback
    try { return JSON.parse(JSON.stringify(value)) }
    catch (e) { return fallback }
  }

  function normalizedSettings(source) {
    var next = cloneObject(source, {}) || {}

    var tunings = ["standard", "drop-d", "drop-c", "half-step", "open-g"]
    next.tuning = tunings.indexOf(next.tuning) >= 0 ? next.tuning : "standard"

    var ref = Number(next.ref === undefined || next.ref === null ? 440 : next.ref)
    next.ref = isFinite(ref) ? clamp(ref, 420, 460) : 440

    var th = Number(next.threshold === undefined || next.threshold === null ? 5 : next.threshold)
    next.threshold = isFinite(th) ? Math.round(clamp(th, 2, 10)) : 5

    var sens = Number(next.sensitivity === undefined || next.sensitivity === null ? 0.5 : next.sensitivity)
    next.sensitivity = isFinite(sens) ? clamp(sens, 0, 1) : 0.5

    var capo = Number(next.capo === undefined || next.capo === null ? 0 : next.capo)
    next.capo = isFinite(capo) ? Math.round(clamp(capo, 0, 11)) : 0

    next.autoListen = !!next.autoListen

    next.autoStop = !!next.autoStop

    var as = Number(next.autoStopSeconds === undefined || next.autoStopSeconds === null ? 15 : next.autoStopSeconds)
    next.autoStopSeconds = isFinite(as) ? Math.round(clamp(as, 5, 60)) : 15

    var modes = ["icon", "icon-text"]
    next.displayMode = modes.indexOf(next.displayMode) >= 0 ? next.displayMode : "icon"

    return next
  }

  function draftValue(name, fallback) {
    var value = draftSettings ? draftSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function setDraftValue(name, value) {
    var next = normalizedSettings(draftSettings)
    next[name] = value
    draftSettings = next
    autosaveTimer.restart()
  }

  function canPersistSettings() {
    return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
  }

  function saveSettings() {
    var next = normalizedSettings(draftSettings)
    draftSettings = next
    root.settings = next
    if (canPersistSettings()) {
      bar.shell.updateEntryInline(root.moduleName, next)
      settingsStatusText = "Saved to shell.json"
    } else {
      settingsStatusText = "Saved for this session"
    }
    if (listening) restartTuner()
  }

  // Silence gate derived from sensitivity: 0 -> 0.020 (quietest) .. 1 -> 0.004
  function gateForSensitivity() {
    return Number((0.020 - draftValue("sensitivity", 0.5) * 0.016).toFixed(4))
  }

  // ---- display state --------------------------------------------------------

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      return decodeURIComponent(value.substring(7))
    return value
  }

  function tuningColor() {
    if (!listening || note === "") return dim
    var th = Math.max(2, Number(root.setting("threshold", 5)))
    var c = Math.abs(cents)
    if (c <= th) return inTune
    if (c <= Math.min(20, th * 4)) return closeColor
    return off
  }

  function statusText() {
    if (note === "") return listening ? "listening…" : "tuner"
    if (Math.abs(cents) > 30) return root.freq.toFixed(1) + " Hz"
    return note + (cents > 0 ? " +" : " ") + Math.round(cents) + "¢"
  }

  // ---- tuner process --------------------------------------------------------

  function buildCommand() {
    return [
      "python3",
      root.pathFromUrl(Qt.resolvedUrl("tuner.py")),
      "--tuning", root.setting("tuning", "standard"),
      "--ref", String(root.setting("ref", 440)),
      "--capo", String(root.setting("capo", 0)),
      "--gate", String(gateForSensitivity())
    ]
  }

  function startTuner() {
    listening = true
    if (!tuner.running) {
      tuner.command = buildCommand()
      tuner.running = true
    }
    if (root.setting("autoStop", false)) silenceTimer.restart()
  }

  function stopTuner() {
    listening = false
    tuner.running = false
    silenceTimer.stop()
    note = ""
    cents = 0
    freq = 0
  }

  function restartTuner() {
    tuner.running = false
    note = ""
    cents = 0
    freq = 0
    tuner.command = buildCommand()
    tuner.running = true
  }

  function toggle() {
    if (listening) {
      stopTuner()
      if (popupOpen) close()
    } else {
      startTuner()
      showTuner()
    }
  }

  // ---- panel ----------------------------------------------------------------

  function close() {
    popupOpen = false
    settingsMode = false
  }

  function openSettings() {
    draftSettings = normalizedSettings(settings)
    settingsStatusText = ""
    settingsMode = true
    popupOpen = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function showTuner() {
    settingsMode = false
    settingsStatusText = ""
    popupOpen = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      if (root.setting("autoListen", false) && !root.listening) startTuner()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  // Debounced auto-save: any draft edit saves after a short settle so
  // spinbox/dropdown/slider tweaks don't hammer shell.json per keystroke.
  Timer {
    id: autosaveTimer
    interval: 400
    repeat: false
    onTriggered: root.saveSettings()
  }

  function triggerPress(button) {
    if (button === Qt.RightButton) {
      if (popupOpen) close()
      else openSettings()
      return
    }
    if (button === Qt.LeftButton) {
      if (settingsMode) { close(); return }
      toggle()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: tuner
    running: false
    command: []

    stdout: SplitParser {
      onRead: function (line) {
        var text = String(line || "").trim()
        if (text.indexOf("T:") === 0) {
          var entries = []
          var parts = text.substring(2).split(",")
          for (var i = 0; i < parts.length; i++) {
            var kv = parts[i].split("@")
            if (kv.length === 2) {
              var target = parseFloat(kv[1])
              if (isFinite(target)) entries.push({ name: kv[0], target: target })
            }
          }
          root.stringTable = entries
          return
        }
        var parts = text.split(/\s+/)
        if (parts.length < 3) return
        var f = parseFloat(parts[0])
        if (!isFinite(f)) return
        root.freq = f
        root.note = parts[1]
        root.cents = parseFloat(parts[2])
        var h = root.history.slice()
        h.push(root.cents)
        if (h.length > 60) h.splice(0, h.length - 60)
        root.history = h
        if (root.setting("autoStop", false)) silenceTimer.restart()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function (text) {
        if (text && text.trim() !== "")
          console.warn("guitar-tuner", text.trim())
      }
    }
  }

  Timer {
    id: silenceTimer
    interval: Math.max(1000, Number(root.setting("autoStopSeconds", 15)) * 1000)
    repeat: false
    onTriggered: {
      if (listening) {
        stopTuner()
        if (bar) bar.showTooltip(button, "Stopped after silence (auto-stop)")
      }
    }
  }

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: barRow.implicitWidth + 12
    implicitHeight: root.barSize

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: 4

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.iconGlyph
        color: root.tuningColor()
        font.family: "Material Symbols Outlined"
        font.pixelSize: 12
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.setting("displayMode", "icon") === "icon-text"
        text: root.statusText()
        color: root.tuningColor()
        font.family: root.fontFamily
        font.pixelSize: 10
        font.bold: true
      }
    }

    property var registeredBar: null

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(button)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(button)
    }

    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(button)

    Connections {
      target: root
      function onBarChanged() { button.syncClickRegistration() }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        if (root.bar && !root.popupOpen) {
          if (root.note !== "")
            root.bar.showTooltip(button, root.statusText() + " · " + root.freq.toFixed(1) + " Hz")
          else
            root.bar.showTooltip(button, root.listening ? "Listening… (click to stop)" : "Guitar tuner (click to listen, right-click for settings)")
        }
      }
      onExited: if (root.bar) root.bar.hideTooltip(button)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: settingsMode && settingsContent.editorActive

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) flick.contentY = root.clamp(flick.contentY + dy * 56, 0, Math.max(0, flick.contentHeight - flick.height))
      }
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.settingsMode ? root.close() : root.openSettings()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 10

        SettingsHeader { visible: root.settingsMode }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        Flickable {
          id: flick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: contentColumn.implicitHeight
          clip: true
          interactive: root.settingsMode
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: contentColumn
            width: flick.width
            spacing: 10

            Text {
              Layout.fillWidth: true
              Layout.topMargin: 12
              visible: !root.settingsMode
              text: root.listening ? "Pluck a string and watch the needle…" : "Guitar tuner — click the bar icon to listen, pluck a string, and watch the color."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: 11
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              Layout.fillWidth: true
              visible: !root.settingsMode
              text: "esc close · s settings · ↑/↓ scroll"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: 10
              horizontalAlignment: Text.AlignHCenter
            }

            LiveSection {
              visible: !root.settingsMode
            }

            SettingsContent {
              id: settingsContent
              visible: root.settingsMode
            }
          }
        }
      }
    }
  }

  component SettingsHeader: RowLayout {
    Layout.fillWidth: true
    spacing: 8

    Text {
      text: "Tuner Settings"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
    }

    Button {
      text: "Done"
      foreground: root.foreground
      tooltipText: "Close settings"
      tooltipBackground: root.background
      tooltipForeground: root.foreground
      fontFamily: root.fontFamily
      fontSize: 10
      horizontalPadding: 8
      verticalPadding: 4
      onClicked: root.close()
    }
  }

  component SectionCard: BorderSurface {
    id: section
    property string title: ""
    property string subtitle: ""
    property color titleColor: foreground
    default property alias content: body.data

    Layout.fillWidth: true
    color: root.card
    borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05), 1)
    padding: 12
    radius: Style.cornerRadius
    implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: section.contentTopInset
      anchors.rightMargin: section.contentRightInset
      anchors.bottomMargin: section.contentBottomInset
      anchors.leftMargin: section.contentLeftInset
      spacing: 8

      PanelSectionHeader {
        visible: section.title !== ""
        Layout.fillWidth: true
        text: section.title
        foreground: section.titleColor
        fontFamily: root.fontFamily
        fontSize: 11
      }
      Text {
        visible: section.subtitle !== ""
        Layout.fillWidth: true
        text: section.subtitle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: 10
        wrapMode: Text.WordWrap
      }
    }
  }

  component LiveSection: ColumnLayout {
    id: liveRoot
    Layout.fillWidth: true
    spacing: 8

    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: 96

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        text: root.listening && root.note !== "" ? root.note : (root.listening ? "…" : "—")
        color: root.tuningColor()
        font.family: root.fontFamily
        font.pixelSize: 64
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 6
        visible: root.listening && root.note !== ""
        text: root.freq.toFixed(1) + " Hz · " + root.statusText()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: 10
      }
    }

    CentsMeter {
      visible: root.listening && root.note !== ""
    }

    StringReference {
      visible: root.stringTable.length > 0
    }

    HistoryGraph {
      visible: root.history.length >= 2
    }
  }

  component CentsMeter: Item {
    Layout.fillWidth: true
    Layout.preferredHeight: 26

    RowLayout {
      anchors.fill: parent
      spacing: 6

      Text {
        text: "-50"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: 9
        Layout.preferredWidth: 22
      }

      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 14

        Rectangle {
          anchors.fill: parent
          radius: 7
          color: root.card
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          border.width: 1
        }

        // 0¢ center tick
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          x: parent.width / 2 - 1
          width: 2
          height: 10
          radius: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
        }

        // needle: clamped to -50..+50
        Rectangle {
          id: needle
          anchors.verticalCenter: parent.verticalCenter
          width: 8
          height: 8
          radius: 4
          color: root.tuningColor()
          x: {
            var clamped = Math.max(-50, Math.min(50, root.cents))
            return parent.width * ((clamped + 50) / 100) - width / 2
          }
        }
      }

      Text {
        text: "+50"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: 9
        Layout.preferredWidth: 22
        horizontalAlignment: Text.AlignRight
      }
    }
  }

  component StringReference: ColumnLayout {
    id: stringRoot
    Layout.fillWidth: true
    spacing: 4

    Text {
      Layout.fillWidth: true
      text: "Strings"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: 10
      font.bold: true
    }

    Repeater {
      model: root.stringTable

      delegate: RowLayout {
        required property var modelData
        Layout.fillWidth: true
        spacing: 8

        readonly property bool isCurrent: root.listening && root.note !== "" && root.note === modelData.name

        Text {
          text: modelData.name
          color: isCurrent ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: 11
          font.bold: isCurrent
          Layout.preferredWidth: 40
        }

        Text {
          text: modelData.target.toFixed(1) + " Hz"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: 10
        }

        Item { Layout.fillWidth: true }

        Text {
          visible: isCurrent
          text: (root.cents > 0 ? "+" : "") + Math.round(root.cents) + "¢"
          color: root.tuningColor()
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: true
        }

        Rectangle {
          width: 8
          height: 8
          radius: 4
          color: isCurrent ? root.tuningColor() : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)
        }
      }
    }
  }

  component HistoryGraph: Canvas {
    id: graph
    Layout.fillWidth: true
    Layout.preferredHeight: 40

    property var samples: root.history

    onSamplesChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)

      // center line (0¢)
      ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, h / 2)
      ctx.lineTo(w, h / 2)
      ctx.stroke()

      var samples = graph.samples || []
      if (samples.length < 2) return

      var last = samples[samples.length - 1]
      var color = root.tuningColor()
      ctx.strokeStyle = Qt.rgba(color.r, color.g, color.b, 0.9)
      ctx.lineWidth = 2
      ctx.beginPath()
      for (var i = 0; i < samples.length; i++) {
        var s = Number(samples[i])
        if (!isFinite(s)) continue
        var x = (i / (samples.length - 1)) * w
        var y = h / 2 - (Math.max(-50, Math.min(50, s)) / 50) * (h / 2 - 2)
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()

      // last point dot
      ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, 1)
      ctx.beginPath()
      var lx = w - 2
      var ly = h / 2 - (Math.max(-50, Math.min(50, last)) / 50) * (h / 2 - 2)
      ctx.arc(lx, ly, 3, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  component SettingsContent: ColumnLayout {
    id: settingsRoot
    Layout.fillWidth: true
    spacing: 10

    readonly property bool editorActive: refField.field.activeFocus || capoField.field.activeFocus || thresholdField.field.activeFocus || autoStopField.field.activeFocus

    // The PanelKeyCatcher is blocked while a spinbox has focus (so arrow
    // keys step the value), and the spinbox itself consumes Escape. With
    // Keys.priority: Keys.BeforeItem this handler fires before the focused
    // editor (or the blocked catcher) sees the key, so Escape always closes
    // the panel — same pattern first-party clock/weather/network editors use.
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.close()
        event.accepted = true
      }
    }

    SectionCard {
      title: "Tuning"

      ColumnLayout {
        width: parent.width
        spacing: 8

        Dropdown {
          label: "Tuning preset"
          width: parent.width
          fontFamily: root.fontFamily
          options: ["standard", "drop-d", "drop-c", "half-step", "open-g"]
          value: String(root.draftValue("tuning", "standard"))
          onChanged: function(v) { root.setDraftValue("tuning", v) }
        }

        NumberField {
          id: refField
          label: "Reference pitch (A4, Hz)"
          value: Number(root.draftValue("ref", 440))
          from: 420
          to: 460
          stepSize: 1
          fieldWidth: parent.width
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onModified: function(value) { root.setDraftValue("ref", value) }
        }

        NumberField {
          id: capoField
          label: "Capo fret (0-11)"
          value: Number(root.draftValue("capo", 0))
          from: 0
          to: 11
          stepSize: 1
          fieldWidth: parent.width
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onModified: function(value) { root.setDraftValue("capo", value) }
        }

        Text {
          Layout.fillWidth: true
          text: "All string pitches follow the reference. 442 = orchestral, 432 = vintage."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: 10
          wrapMode: Text.WordWrap
        }
      }
    }

    SectionCard {
      title: "Detection"

      ColumnLayout {
        width: parent.width
        spacing: 8

        NumberField {
          id: thresholdField
          label: "In-tune threshold (± cents)"
          value: Number(root.draftValue("threshold", 5))
          from: 2
          to: 10
          stepSize: 1
          fieldWidth: parent.width
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onModified: function(value) { root.setDraftValue("threshold", value) }
        }

        Text {
          Layout.fillWidth: true
          text: "Green up to this many cents off; yellow up to 4x, red beyond."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: 10
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          Layout.topMargin: 6
          text: "Mic sensitivity: " + Math.round(Number(root.draftValue("sensitivity", 0.5)) * 100) + "%"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: true
        }

        PanelSlider {
          Layout.fillWidth: true
          bar: root.bar
          value: Number(root.draftValue("sensitivity", 0.5))
          minimum: 0
          maximum: 1
          step: 0.05
          onMoved: function(v) { root.setDraftValue("sensitivity", v) }
        }

        Toggle {
          label: "Auto-listen on panel open"
          description: "Starts listening automatically whenever the panel opens."
          checked: !!root.draftValue("autoListen", false)
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: root.setDraftValue("autoListen", !root.draftValue("autoListen", false))
        }

        Toggle {
          label: "Auto-stop after silence"
          description: "Stops listening after a quiet spell — saves battery and closes the mic."
          checked: !!root.draftValue("autoStop", false)
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: root.setDraftValue("autoStop", !root.draftValue("autoStop", false))
        }

        NumberField {
          id: autoStopField
          label: "Auto-stop delay (seconds)"
          value: Number(root.draftValue("autoStopSeconds", 15))
          from: 5
          to: 60
          stepSize: 5
          fieldWidth: parent.width
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onModified: function(value) { root.setDraftValue("autoStopSeconds", value) }
        }
      }
    }

    SectionCard {
      title: "Display"

      ColumnLayout {
        width: parent.width
        spacing: 8

        Dropdown {
          label: "Display mode"
          width: parent.width
          fontFamily: root.fontFamily
          options: ["icon", "icon-text"]
          value: String(root.draftValue("displayMode", "icon"))
          onChanged: function(v) { root.setDraftValue("displayMode", v) }
        }

        Text {
          Layout.fillWidth: true
          text: "icon keeps the bar compact; icon-text also shows the note and cents."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: 10
          wrapMode: Text.WordWrap
        }
      }
    }

    Text {
      visible: root.settingsStatusText !== ""
      Layout.fillWidth: true
      text: root.settingsStatusText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      Layout.fillWidth: true
      text: "changes auto-save · esc closes"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
    }
  }

  Component.onDestruction: if (tuner.running) tuner.running = false
}