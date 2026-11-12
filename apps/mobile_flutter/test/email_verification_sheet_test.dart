import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/auth/email_verification_sheet.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

class _Memory extends DemoPersistence {
  String token = 'alice';
  @override
  Future<String?> loadAccessToken() async => token;
}

ResponseBody _response(Map<String, dynamic> body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _Backend implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  bool wrongCode = false;
  bool failRequest = false;
  bool alreadyVerified = false;
  bool confirmed = false;
  Completer<ResponseBody>? pendingConfirm;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final owner = (options.headers['Authorization'] as String).replaceFirst(
      'Bearer ',
      '',
    );
    if (options.path == '/users/me') return _response({'id': owner});
    if (options.path == '/auth/email-verification/request') {
      if (failRequest) {
        return _response({
          'detail': 'Wait before requesting another code.',
        }, 429);
      }
      return _response({
        'sent': !alreadyVerified,
        'already_verified': alreadyVerified,
        if (!alreadyVerified) 'verification_sent_to': '$owner@example.com',
      });
    }
    if (options.path == '/auth/email-verification/confirm') {
      if (pendingConfirm != null) return pendingConfirm!.future;
      if (wrongCode) {
        return _response({
          'detail': 'The verification code is incorrect or expired.',
        }, 400);
      }
      confirmed = true;
      return _response({'id': owner, 'email_verified': true});
    }
    return _response({'detail': 'Unexpected route'}, 404);
  }

  @override
  void close({bool force = false}) {}

  EmailVerificationApi api(_Memory memory) => EmailVerificationApi(
    Dio(BaseOptions(baseUrl: 'https://not-real.invalid'))
      ..httpClientAdapter = this,
    memory,
  );
}

final _owner = StateProvider((_) => 'alice');

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Backend backend,
  _Memory memory,
  void Function(bool) onResult,
) async {
  final container = ProviderContainer(
    overrides: [
      emailVerificationApiProvider.overrideWithValue(backend.api(memory)),
      meProvider.overrideWith((ref) async {
        final owner = ref.watch(_owner);
        return DemoSeed.me.copyWith(
          id: owner,
          email: '$owner@example.com',
          emailVerified: false,
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await container.read(meProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('Open verification'),
              onPressed: () async => onResult(
                await showEmailVerificationSheet(
                  context,
                  accountId: 'alice',
                  email: 'alice@example.com',
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open verification'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('Messages exposes verification and refreshes confirmed status', (
    tester,
  ) async {
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        emailVerificationApiProvider.overrideWithValue(backend.api(_Memory())),
        meProvider.overrideWith(
          (_) async => DemoSeed.me.copyWith(
            id: 'alice',
            email: 'alice@example.com',
            emailVerified: backend.confirmed,
          ),
        ),
        directMessageThreadsProvider.overrideWith(
          (_) => DirectMessageThreadsNotifier.testing([]),
        ),
        joinedEventChatsProvider.overrideWith((_) async => []),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DirectMessagesPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messages-verify-email')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('messages-verify-email')));
    await tester.pumpAndSettle();
    expect(backend.calls, isEmpty);
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('email-verification-code')),
      '123456',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Verify email'));
    await tester.pumpAndSettle();
    expect(container.read(meProvider).valueOrNull!.emailVerified, isTrue);
    expect(find.byKey(const ValueKey('messages-verify-email')), findsNothing);
    expect(
      find.text('Email verified. You can now send messages.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'sends only on explicit request and confirms the signed-in owner',
    (tester) async {
      final backend = _Backend();
      bool? result;
      await _show(tester, backend, _Memory(), (value) => result = value);
      expect(backend.calls, isEmpty);
      expect(find.text('Send code'), findsOneWidget);
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(backend.calls.map((call) => call.path), [
        '/users/me',
        '/auth/email-verification/request',
      ]);
      expect(backend.calls.last.data, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('email-verification-code')),
        '123456',
      );
      await tester.tap(find.text('Verify email'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(backend.calls.last.data, {'code': '123456'});
    },
  );

  testWidgets('wrong code retains input and never reports success', (
    tester,
  ) async {
    final backend = _Backend()..wrongCode = true;
    bool? result;
    await _show(tester, backend, _Memory(), (value) => result = value);
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    final code = find.byKey(const ValueKey('email-verification-code'));
    await tester.enterText(code, '000000');
    await tester.tap(find.text('Verify email'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(
      find.text('The verification code is incorrect or expired.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(code).controller!.text, '000000');
    backend.wrongCode = false;
    await tester.enterText(code, '123456');
    await tester.tap(find.text('Verify email'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('account switch cannot apply a pending confirmation', (
    tester,
  ) async {
    final backend = _Backend();
    final memory = _Memory();
    bool? result;
    final container = await _show(
      tester,
      backend,
      memory,
      (value) => result = value,
    );
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('email-verification-code')),
      '123456',
    );
    backend.pendingConfirm = Completer<ResponseBody>();
    await tester.tap(find.text('Verify email'));
    await tester.pump();
    memory.token = 'bob';
    container.read(_owner.notifier).state = 'bob';
    backend.pendingConfirm!.complete(
      _response({'id': 'alice', 'email_verified': true}),
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(
      find.text('Your account changed. Close this window and try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('email-verification-code')), findsNothing);
    expect(find.text('Verify email'), findsNothing);
  });

  testWidgets(
    'failed delivery never exposes confirmation or claims code sent',
    (tester) async {
      final backend = _Backend()..failRequest = true;
      bool? result;
      await _show(tester, backend, _Memory(), (value) => result = value);
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('Wait before requesting another code.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('email-verification-code')),
        findsNothing,
      );
      expect(find.text('Send code'), findsOneWidget);
    },
  );

  testWidgets(
    'already verified closes without claiming another code was sent',
    (tester) async {
      final backend = _Backend()..alreadyVerified = true;
      bool? result;
      await _show(tester, backend, _Memory(), (value) => result = value);
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(
        backend.calls.where((call) => call.path.endsWith('/confirm')),
        isEmpty,
      );
    },
  );

  test(
    'account mismatch rejects before sending a verification email',
    () async {
      final backend = _Backend();
      await expectLater(
        backend.api(_Memory()).openSession('bob'),
        throwsStateError,
      );
      expect(backend.calls.map((call) => call.path), ['/users/me']);
    },
  );
}
