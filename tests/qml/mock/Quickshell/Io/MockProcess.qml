import QtQuick

Item {
  id: mock
  width: 0
  height: 0
  visible: false
  property var command: []
  property var environment: ({})
  property bool running: false
  property var stdout: null
  property var stderr: null
  property bool finishing: false

  signal exited(int code)

  Timer {
    id: progressTimer
    interval: 8
    repeat: false
    onTriggered: {
      if (mock.command.length > 2 && mock.command[2] === "scan")
        mock.stderr.read('{"protocol":1,"type":"stage","stage":"scan","cancellable":true,"message":"Scanning"}\n')
      else if (mock.command.length > 2 && mock.command[2] === "commit")
        mock.stderr.read('{"protocol":1,"type":"stage","stage":"commit","cancellable":false,"message":"Committing"}\n')
    }
  }

  Timer {
    id: finishTimer
    interval: 40
    repeat: false
    onTriggered: mock.finish(0)
  }

  onRunningChanged: {
    if (running) {
      finishing = false
      var delay = command.length > 1 ? Number(command[1]) : 40
      finishTimer.interval = Math.max(1, isFinite(delay) ? delay : 40)
      progressTimer.start()
      finishTimer.start()
    } else if (!finishing) {
      progressTimer.stop()
      finishTimer.stop()
      Qt.callLater(function() {
        mock.finishing = true
        mock.exited(143)
        mock.finishing = false
      })
    }
  }

  function finish(code) {
    if (!running) return
    finishing = true
    progressTimer.stop()
    if (stdout) stdout.text = command.join(" ")
    running = false
    exited(code)
    finishing = false
  }
}
