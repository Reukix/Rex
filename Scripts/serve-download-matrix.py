#!/usr/bin/env python3
import http.server
import pathlib
import sys


CONTENT_TYPES = {
    "/safe.pdf": "application/pdf",
    "/installer.pkg": "application/vnd.apple.installer+xml",
    "/setup.sh": "application/x-sh",
    "/invoice.pdf.command": "application/octet-stream",
    "/photo.png": "text/html",
}
DOWNLOAD_PATHS = frozenset(CONTENT_TYPES)


class MatrixHandler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        return CONTENT_TYPES.get(self.path.split("?", 1)[0], super().guess_type(path))

    def end_headers(self):
        request_path = self.path.split("?", 1)[0]
        if request_path in DOWNLOAD_PATHS:
            filename = pathlib.PurePosixPath(request_path).name
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        super().end_headers()

    def log_message(self, format, *args):
        sys.stderr.write("[download-matrix] " + format % args + "\n")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: serve-download-matrix.py <fixture-root> <port-file>")
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    port_file = pathlib.Path(sys.argv[2])
    handler = lambda *args, **kwargs: MatrixHandler(*args, directory=str(root), **kwargs)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port_file.write_text(str(server.server_port), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
