import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../acp/acp_message.dart';

/// A tool of the harness's MCP vocabulary, as this client answers it.
class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.readOnly = false,
  });

  final String name;
  final String title;
  final String description;
  final Map<String, Object?> inputSchema;
  final Future<Map<String, Object?>> Function(Map<String, Object?> arguments)
  handler;
  final bool readOnly;

  Map<String, Object?> toWire() => <String, Object?>{
    'name': name,
    'title': title,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': <String, Object?>{'readOnlyHint': readOnly},
  };
}

/// A CallToolResult, worded for the model and with its machine-readable data.
Map<String, Object?> mcpTextResult(
  String text, {
  bool isError = false,
  Map<String, Object?>? structured,
}) => <String, Object?>{
  'content': <Object?>[
    <String, Object?>{'type': 'text', 'text': text},
  ],
  if (isError) 'isError': true,
  if (structured != null) 'structuredContent': structured,
};

/// A picture in two forms: bytes for the harness's screen tools, text for
/// the model when the tool is called directly.
Map<String, Object?> mcpImageResult(
  Uint8List png, {
  required int width,
  required int height,
  String? note,
}) => mcpTextResult(
  'Picture ${png.length} B, ${width}x$height px${note == null ? '' : ' ($note)'}',
  structured: <String, Object?>{
    'data': base64Encode(png),
    'mime': 'image/png',
    'width': width,
    'height': height,
    if (note != null) 'note': note,
  },
);

/// One MCP server this client runs, speaking JSON-RPC 2.0 over the messages
/// the harness carries on `_harness/computer/mcp`.
///
/// Only the four methods MCP defines are answered (`initialize`, `ping`,
/// `tools/list`, `tools/call`); a notification gets no response and every
/// other request is a protocol error, as the harness's own MCP server does.
class McpServer {
  McpServer({
    required this.name,
    required this.title,
    required this.version,
    required this.instructions,
    required this.tools,
  });

  final String name;
  final String title;
  final String version;
  final String instructions;
  final List<McpTool> tools;

  static const protocolVersion = '2025-06-18';
  static const supportedVersions = <String>[
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];

  McpTool? toolNamed(String name) {
    for (final tool in tools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  /// Answer one message; null for a notification, which has no answer.
  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final method = asString(message['method']);
    final id = message['id'];
    if (method == null || method.isEmpty) {
      return id == null ? null : _error(id, -32600, 'Not a JSON-RPC request');
    }
    if (id == null) {
      // notifications/initialized and notifications/cancelled need nothing.
      return null;
    }
    final params = asMap(message['params']);
    try {
      switch (method) {
        case 'initialize':
          final asked = asString(params['protocolVersion']);
          final protocol = asked != null && supportedVersions.contains(asked)
              ? asked
              : protocolVersion;
          return _result(id, <String, Object?>{
            'protocolVersion': protocol,
            'capabilities': <String, Object?>{
              'tools': <String, Object?>{'listChanged': false},
            },
            'serverInfo': <String, Object?>{
              'name': name,
              'title': title,
              'version': version,
            },
            'instructions': instructions,
          });
        case 'ping':
          return _result(id, const <String, Object?>{});
        case 'tools/list':
          return _result(id, <String, Object?>{
            'tools': <Object?>[for (final tool in tools) tool.toWire()],
          });
        case 'tools/call':
          final tool = toolNamed(asString(params['name']) ?? '');
          if (tool == null) {
            return _error(
              id,
              -32602,
              'Unknown tool: ${asString(params['name']) ?? ''}',
            );
          }
          final arguments = asMap(params['arguments']);
          try {
            final result = await tool.handler(arguments);
            return _result(id, result);
          } catch (failure) {
            return _result(
              id,
              mcpTextResult('Tool failed: $failure', isError: true),
            );
          }
        default:
          return _error(id, -32601, 'Method not found: $method');
      }
    } catch (failure) {
      return _error(id, -32603, 'Internal error: $failure');
    }
  }

  Map<String, Object?> _result(Object? id, Map<String, Object?> result) =>
      <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};

  Map<String, Object?> _error(Object? id, int code, String message) =>
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      };
}

/// An MCP tool whose handler may be synchronous, as most file tools are.
McpTool mcpSyncTool({
  required String name,
  required String title,
  required String description,
  required Map<String, Object?> inputSchema,
  required FutureOr<Map<String, Object?>> Function(
    Map<String, Object?> arguments,
  )
  handler,
  bool readOnly = false,
}) => McpTool(
  name: name,
  title: title,
  description: description,
  inputSchema: inputSchema,
  readOnly: readOnly,
  handler: (arguments) async => await handler(arguments),
);
