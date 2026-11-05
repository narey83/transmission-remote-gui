#!/usr/bin/env python3
"""Move shares Add's remote folders, favorites and history, against an isolated RPC fixture."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import trgui_uitest as ui

SHEET = "sheet 1 of window 1"
TABLE = "table 1 of scroll area 1 of group 1 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1"
rows = [{"id": 7, "name": "Move folder fixture", "hashString": "a" * 40,
         "downloadDir": "/downloads", "status": 0, "percentDone": 0,
         "totalSize": 100, "sizeWhenDone": 100, "leftUntilDone": 100,
         "trackers": [], "trackerStats": [], "labels": []}]
moves = []
unexpected = []
reject_next_move = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global reject_next_move
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, args = request["method"], request.get("arguments", {})
        result, response = "success", {}
        if method == "torrent-get":
            response = {"torrents": [{key: value for key, value in row.items()
                        if key in args.get("fields", row)} for row in rows]}
        elif method == "session-get":
            response = {"download-dir": "/downloads", "rpc-version": 17, "version": "4.0.5"}
        elif method == "session-stats":
            response = {"downloadSpeed": 0, "uploadSpeed": 0, "torrentCount": 1}
        elif method == "free-space":
            response = {"path": args.get("path"), "size-bytes": 1000000000}
        elif method == "torrent-set-location":
            moves.append(args)
            if reject_next_move:
                reject_next_move = False
                result = "permission denied"
            else:
                for row in rows:
                    if row["id"] in args["ids"]:
                        row["downloadDir"] = args["location"]
        else:
            unexpected.append(method)
            result = "unexpected method refused"
        payload = json.dumps({"result": result, "arguments": response}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def open_move():
    ui.activate()
    ui.wait_for(lambda: ui.ax(f"count rows of {TABLE}") == "1", what="fixture torrent")
    x, y = ui.position(f"UI element 1 of row 1 of {TABLE}")
    ui.context_menu_pick(x, y, ui.KEY_MOVE)
    ui.wait_for(lambda: ui.id_exists("move.location", SHEET), what="Move sheet")


def choose(identifier, path):
    ui.id_click(identifier, SHEET)
    ui.ax(f"keystroke {json.dumps(path)}\nkey code 36")
    ui.wait_for(lambda: ui.id_value("move.location", SHEET) == path, what=f"selected {path}")


def cancel():
    ui.id_click("move.cancel", SHEET)
    ui.wait_for(lambda: ui.ax(f"exists {SHEET}") == "false", what="Move cancelled")


def main():
    global reject_next_move
    mock = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    ui.PORT = mock.server_port
    ui.RPC = f"http://127.0.0.1:{ui.PORT}/transmission/rpc"
    ui.ensure_daemon = lambda: None
    try:
        ui.setup(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ui.ROOT, "dist", "Transmission Remote GUI.app"))
        support = Path(ui.HOME) / "Library" / "Application Support" / "Transwift"
        configs = json.loads((support / "servers.json").read_text())
        configs[0]["pathMappings"] = [{"remotePath": path, "localPath": "/Volumes/Fixture" + path}
                                      for path in ["/downloads", "/movies", "/shows"]]
        (support / "servers.json").write_text(json.dumps(configs))
        history_path = support / "download-dirs.json"
        history_path.write_text(json.dumps({ui.SERVER_ID: {"favorites": ["/favorite"], "recent": ["/recent"]}}))
        ui.defaults("appLanguage", "english")
        ui.launch()
        # CoreGraphics can redact window titles before Screen Recording is granted.
        # Verify the same server identity through the Accessibility channel used below,
        # waiting for SwiftUI to update the title after the initial connection.
        ui.wait_for(lambda: "uitest-tr3" in ui.ax("get name of every window"),
                    what="the isolated server in the accessible window title")

        open_move()
        assert ui.id_value("move.location", SHEET) == "/downloads"
        choose("move.location.mappings", "/movies")
        cancel()
        assert not moves, "choosing a mapped path or cancelling submitted a move"
        print("PASS: mapped remote folders are selectable; Cancel submits nothing")

        open_move()
        choose("move.location.menu", "/favorite")
        choose("move.location.menu", "/recent")
        ui.id_type("move.location", "/new-favorite", SHEET)
        ui.id_click("move.location.favorite", SHEET)
        ui.wait_for(lambda: "/new-favorite" in json.loads(history_path.read_text())[ui.SERVER_ID]["favorites"],
                    what="shared favorite persisted")
        cancel()
        print("PASS: favorites and recent folders are selectable; the star shares Add's saved choices")

        open_move()
        ui.id_type("move.location", "relative/folder", SHEET)
        assert not ui.id_enabled("move.submit", SHEET), "relative destination accepted"
        assert ui.id_exists("move.location.error", SHEET)
        ui.id_type("move.location", "", SHEET)
        assert not ui.id_enabled("move.submit", SHEET), "empty destination accepted"
        cancel()
        assert not moves
        print("PASS: relative and empty paths cannot be submitted")

        open_move()
        choose("move.location.mappings", "/movies")
        reject_next_move = True
        ui.id_click("move.submit", SHEET)
        ui.wait_for(lambda: ui.id_exists("move.error", SHEET), what="inline daemon error")
        assert "permission denied" in ui.ax_id("move.error", "return description of e", SHEET)
        assert json.loads(history_path.read_text())[ui.SERVER_ID]["recent"] == ["/recent"]
        print("PASS: a rejected move stays open with an inline error and does not enter history")

        ui.id_click("move.moveData", SHEET)
        ui.id_click("move.submit", SHEET)
        ui.wait_for(lambda: len(moves) == 2, what="retried move request")
        ui.wait_for(lambda: ui.ax(f"exists {SHEET}") == "false", what="successful Move closes")
        assert moves == [{"ids": [7], "location": "/movies", "move": True},
                         {"ids": [7], "location": "/movies", "move": False}], moves
        ui.wait_for(lambda: json.loads(history_path.read_text())[ui.SERVER_ID]["recent"][0] == "/movies",
                    what="successful move recorded in shared history")
        assert not unexpected, unexpected
        ui.screenshot(os.path.join(ui.WORK, "move-download-dir-final.png"))
        print("PASS: chosen remote folder and move-data flag reach the selected torrent; success records history")
    finally:
        ui.teardown()
        mock.shutdown()
        mock.server_close()


if __name__ == "__main__":
    main()
