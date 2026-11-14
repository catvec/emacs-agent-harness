#!/usr/bin/env python3
"""A tiny OTLP/HTTP JSON collector, for trying the harness's otel module.

It accepts POST /v1/traces and POST /v1/metrics with the JSON encoding of
OTLP -- the envelope the module sends -- and prints a one-line summary per
request: how many spans or metric data points arrived, their names and
kinds.  It answers 200 with the OTLP JSON success body, as a collector
does.  Nothing is stored and nothing is forwarded: this is a stand-in for
a real collector so that a reviewer can see the export happen.

Usage:
  ./collector.py [PORT]        (default 4318, the OTLP/HTTP port)
  ./collector.py --verbose     print every attribute name and value
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


VERBOSE = False


def spans_of(body):
    """Return [(name, kind, parent, attributes)] from a traces body."""
    out = []
    for resource_spans in body.get("resourceSpans", []):
        for scope_spans in resource_spans.get("scopeSpans", []):
            for span in scope_spans.get("spans", []):
                attrs = {
                    a.get("key"): value_of(a.get("value"))
                    for a in span.get("attributes", [])
                }
                out.append(
                    (span.get("name"), span.get("kind"),
                     span.get("parentSpanId"), attrs)
                )
    return out


def metrics_of(body):
    """Return [(name, kind, unit, [data points])] from a metrics body."""
    out = []
    for resource_metrics in body.get("resourceMetrics", []):
        for scope_metrics in resource_metrics.get("scopeMetrics", []):
            for metric in scope_metrics.get("metrics", []):
                kind = "histogram" if "histogram" in metric else "sum"
                points = metric.get(kind, {}).get("dataPoints", [])
                out.append((metric.get("name"), kind, metric.get("unit"), points))
    return out


def value_of(value):
    """Return an OTLP JSON attribute value as a Python value."""
    if not isinstance(value, dict):
        return value
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in value:
            raw = value[key]
            if key == "intValue":
                try:
                    return int(raw)
                except (TypeError, ValueError):
                    return raw
            return raw
    return value


def attributes_of(point):
    return {a.get("key"): value_of(a.get("value"))
            for a in point.get("attributes", [])}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except ValueError as err:
            self.answer(400, {"error": "not JSON: %s" % err})
            return
        if self.path.endswith("/v1/traces"):
            self.show_traces(body)
        elif self.path.endswith("/v1/metrics"):
            self.show_metrics(body)
        else:
            self.answer(404, {"error": "no signal at %s" % self.path})
            return
        self.answer(200, {})

    def show_traces(self, body):
        spans = spans_of(body)
        print("traces  %d span%s" % (len(spans), "" if len(spans) == 1 else "s"))
        for name, kind, parent, attrs in spans:
            kind_name = {0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER",
                         3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}.get(kind, kind)
            print("  %-42s %-10s parent %s"
                  % (name, kind_name, parent or "(root)"))
            if VERBOSE:
                for key in sorted(attrs):
                    print("      %s = %s" % (key, attrs[key]))
        sys.stdout.flush()

    def show_metrics(self, body):
        metrics = metrics_of(body)
        print("metrics %d instrument%s"
              % (len(metrics), "" if len(metrics) == 1 else "s"))
        for name, kind, unit, points in metrics:
            for point in points:
                attrs = attributes_of(point)
                value = point.get("sum", point.get("asInt", point.get("count")))
                print("  %-48s %-10s %s %s"
                      % (name, kind, unit, value))
                if VERBOSE:
                    for key in sorted(attrs):
                        print("      %s = %s" % (key, attrs[key]))
        sys.stdout.flush()

    def answer(self, status, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    global VERBOSE
    args = [a for a in sys.argv[1:] if a != "--verbose"]
    VERBOSE = "--verbose" in sys.argv[1:]
    port = int(args[0]) if args else 4318
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("OTLP/HTTP JSON collector on http://127.0.0.1:%d" % port)
    print("  set harness-otel-endpoint to that URL and harness-otel-enabled to t")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
