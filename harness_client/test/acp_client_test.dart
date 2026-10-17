import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/acp/capabilities.dart';
import 'package:harness_client/src/acp/connection_target.dart';
import 'package:harness_client/src/models/transcript.dart';

import 'support/fake_harness.dart';

void main() {
  group('ACP client', () {
    test('initializes, detects capabilities, and pages sessions', () async {
      final harness = FakeHarness();
      final transport = await harness.open(
        ConnectionTarget.parse('ws://memory/acp'),
        '',
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      final result = await client.initialize();
      final caps = HarnessCapabilities.fromInitialize(result);
      expect(caps.isHarness, isTrue);
      expect(caps.agentName, 'emacs-agent-harness');
      expect(caps.tasks, isTrue);
      expect(caps.usage, isTrue);
      expect(caps.richNodes, isTrue);
      expect(caps.extensionCount, greaterThan(20));

      final list = asMap(await client.request('session/list'));
      final sessions = asMapList(list['sessions']);
      expect(sessions, hasLength(4));
      expect(sessions.first['title'], isNotNull);
    });

    test('answers an agent request and carries a turn to a result', () async {
      final harness = FakeHarness();
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      await client.initialize();
      final updates = <String>[];
      final subscription = client.notifications.listen((notification) {
        if (notification.method == 'session/update') {
          updates.add(
            asStringOr(
              asMap(notification.params['update'])['sessionUpdate'],
              '',
            ),
          );
        }
      });
      addTearDown(subscription.cancel);
      client.requestHandler = (method, params) async {
        if (method == 'session/request_permission') {
          return {
            'outcome': {'outcome': 'selected', 'optionId': 'allow-once'},
          };
        }
        return <String, Object?>{};
      };
      final result = asMap(
        await client.request('session/prompt', {
          'sessionId': 's1',
          'prompt': [
            {'type': 'text', 'text': 'run the tests with permission'},
          ],
        }, Duration.zero),
      );
      expect(result['stopReason'], 'end_turn');
      expect(harness.prompts, contains('run the tests with permission'));
      expect(harness.permissionAnswers, hasLength(1));
      expect(updates, contains('agent_message_chunk'));
      expect(updates, contains('tool_call'));
      expect(updates, contains('tool_call_update'));
      expect(updates, contains('plan'));
    });

    test('surfaces a JSON-RPC error', () async {
      final harness = FakeHarness(enhanced: false);
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      await client.initialize();
      await expectLater(
        client.request('_harness/harness/version'),
        throwsA(isA<AcpException>()),
      );
    });

    test('authentication is requested when a token is configured', () async {
      final harness = FakeHarness(token: 's3cret');
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      final init = await client.initialize();
      final methods = HarnessCapabilities.fromInitialize(init).authMethods;
      expect(methods.any((method) => method.isToken), isTrue);
      await expectLater(
        client.request('session/list'),
        throwsA(isA<AcpException>().having((e) => e.code, 'code', -32000)),
      );
      await client.authenticate(methodId: 'token', token: 's3cret');
      final list = asMap(await client.request('session/list'));
      expect(asMapList(list['sessions']), isNotEmpty);
    });

    test('closing fails pending requests', () async {
      final harness = FakeHarness();
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      await client.initialize();
      final pending = client.request('_harness/session/test-hang');
      final expectation = expectLater(pending, throwsA(isA<AcpException>()));
      await client.close();
      await expectation;
      expect(client.isClosed, isTrue);
    });
  });

  group('connection addresses', () {
    test('websocket, tcp and bare host:port parse', () {
      expect(
        ConnectionTarget.parse('ws://phone:4276').webSocketUri.toString(),
        'ws://phone:4276/acp',
      );
      expect(ConnectionTarget.parse('wss://h/acp').isTcp, isFalse);
      expect(ConnectionTarget.parse('tcp://127.0.0.1:1234').isTcp, isTrue);
      expect(ConnectionTarget.parse('127.0.0.1:1234').isTcp, isTrue);
      expect(
        ConnectionTarget.parse('phone:4276', web: true).webSocketUri.toString(),
        'ws://phone:4276/acp',
      );
    });

    test('a pairing link explains the next step', () {
      expect(
        () => ConnectionTarget.parse('http://h:4276/pair?code=x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ConnectionTarget.parse(
          'http://h:4276/pair?code=x'.replaceFirst('http', 'ws'),
        ),
        returnsNormally,
      );
    });

    test('the token is added to the WebSocket query', () {
      final target = ConnectionTarget.parse('ws://h/ap c'.replaceAll(' ', ''));
      expect(target.uriWithToken('abc')!.queryParameters['token'], 'abc');
    });
  });

  group('transcript reduction', () {
    test('chunks, a tool call and its result become one rendered call', () {
      final transcript = TranscriptState();
      transcript.addLocalUser('run it');
      transcript.apply({
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': 'run it'},
        '_harness': {'nodeId': 'u1'},
      });
      transcript.apply({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'On '},
        '_harness': {'nodeId': 'a1'},
      });
      transcript.apply({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'it.'},
        '_harness': {'nodeId': 'a1'},
      });
      transcript.apply({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'title': 'Run tests',
        'status': 'in_progress',
        'rawInput': {'command': 'flutter test'},
        '_harness': {'nodeId': 't1', 'tool': 'bash'},
      });
      transcript.apply({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': 'completed',
        'rawOutput': 'All good',
        '_harness': {'nodeId': 'r1'},
      });
      expect(transcript.items, hasLength(3));
      expect(transcript.items[1].text, 'On it.');
      expect(transcript.toolsByCallId['c1']!.status, 'completed');
      expect(transcript.toolsByCallId['c1']!.output, 'All good');
      expect(transcript.items.where((item) => item.isUser), hasLength(1));
    });

    test('a final node replaces streamed text', () {
      final transcript = TranscriptState();
      transcript.apply({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'half'},
        '_harness': {'nodeId': 'a1'},
      });
      transcript.applyNode({
        'id': 'a1',
        'kind': 'assistant',
        'content': 'half and the rest',
        'meta': {'model': 'claude:x'},
      });
      expect(transcript.items.single.text, 'half and the rest');
      expect(transcript.items.single.settled, isTrue);
      expect(transcript.items.single.node?['id'], 'a1');
    });

    test('plan and sender information are kept', () {
      final transcript = TranscriptState();
      transcript.apply({
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'one', 'status': 'completed'},
          {'content': 'two', 'status': 'in_progress'},
        ],
      });
      expect(transcript.plan, hasLength(2));
      expect(transcript.plan.last.isActive, isTrue);
      expect(
        formatSender({'kind': 'system', 'source': 'tasks'}),
        'Harness · tasks',
      );
      expect(
        formatSender({'kind': 'session', 'name': 'Sub-agent'}),
        'Sub-agent',
      );
    });
  });
}
