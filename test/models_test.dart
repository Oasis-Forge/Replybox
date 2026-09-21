import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/normalise.dart';
import 'package:replybox/models/record.dart';
import 'package:replybox/models/source_app.dart';

import 'helpers.dart';

void main() {
  group('round trips', () {
    test('a conversation survives toMap and back', () {
      final Conversation before = aConversation(
        title: 'Grace Hopper',
        isGroup: true,
        readThroughAt: t0,
      );
      final Conversation after = Conversation.fromMap(before.toMap());

      expect(after.id, before.id);
      expect(after.package, before.package);
      expect(after.conversationKey, before.conversationKey);
      expect(after.keySource, before.keySource);
      expect(after.title, before.title);
      expect(after.isGroup, before.isGroup);
      expect(after.lastMessageAt, before.lastMessageAt);
      expect(after.readThroughAt, before.readThroughAt);
    });

    test('a message survives toMap and back', () {
      final Message before = aMessage(
        conversationId: 'c1',
        text: 'héllo',
        sendState: SendState.pending,
        direction: Direction.outbound,
      );
      final Message after = Message.fromMap(before.toMap());

      expect(after.text, 'héllo');
      expect(after.sendState, SendState.pending);
      expect(after.direction, Direction.outbound);
      expect(after.sentAt, before.sentAt);
      expect(after.historyIndex, before.historyIndex);
    });

    test('an app survives toMap and back', () {
      final SourceApp before = SourceApp.seen(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabled: true,
        at: t0,
      );
      final SourceApp after = SourceApp.fromMap(before.toMap());

      expect(after.package, before.package);
      expect(after.enabled, isTrue);
      expect(after.lastSeenAt, before.lastSeenAt);
    });
  });

  group('copyWith sentinel', () {
    test('clearing a nullable field differs from leaving it alone', () {
      final Conversation c = aConversation(readThroughAt: t0);

      expect(c.copyWith().readThroughAt, t0);
      expect(c.copyWith(readThroughAt: null).readThroughAt, isNull);
    });

    test('undeleting is expressible', () {
      final Conversation deleted = aConversation().copyWith(deletedAt: t0);
      expect(deleted.isDeleted, isTrue);
      expect(deleted.copyWith(deletedAt: null).isDeleted, isFalse);
    });
  });

  group('CAP-8 the kind decides whether text exists', () {
    test('a hidden message has no text even when text is passed', () {
      final Message m = aMessage(
        conversationId: 'c1',
        kind: MessageKind.hidden,
        text: 'Sensitive notification content hidden',
      );
      expect(m.text, isNull);
    });

    test('two hidden messages do not collide on their text hash', () {
      // Hashing an empty text to a constant would make every hidden message
      // in a thread look like the same message to CAP-5's cross-key match.
      expect(Message.hashText(null), '');
      expect(Message.hashText(''), '');
    });

    test('the same text always hashes the same', () {
      expect(Message.hashText('hello'), Message.hashText('hello'));
      expect(Message.hashText('hello'), isNot(Message.hashText('Hello')));
    });
  });

  group('INB-2 an unnamed conversation', () {
    test('is decided by the empty title, not by how the key was resolved', () {
      // The redaction fixture: a real notification carrying shortcutId "1"
      // with an empty title and no conversationTitle at all. A conversation
      // can hold a perfectly good key and still have no name.
      final Conversation c = aConversation(
        title: '',
        key: '1',
        keySource: KeySource.shortcutId,
      );

      expect(c.isUnnamed, isTrue);
      expect(c.keySource, KeySource.shortcutId);
    });
  });

  group('LANG-4 normalisation', () {
    test('ignores case', () {
      expect(normalise('Ada'), normalise('ada'));
    });

    test('ignores accents', () {
      expect(normalise('café'), 'cafe');
      expect(normalise('Ångström'), 'angstrom');
    });

    test('matches the Turkish dotted and dotless i', () {
      // A Turkish user searching "istanbul" must find "İstanbul", and an
      // English user searching "I" must find "i".
      expect(normalise('İstanbul'), normalise('istanbul'));
      expect(normalise('IŞIK'), normalise('ışık'));
      expect(normalise('I'), normalise('i'));
    });

    test('leaves scripts it does not know alone rather than mangling them', () {
      expect(normalise('日本語'), '日本語');
      expect(normalise('مرحبا'), 'مرحبا');
    });

    test('is empty for empty input', () {
      expect(normalise(''), '');
    });
  });

  group('REC-2 ids', () {
    test('two records never share an id', () {
      final Set<String> ids = <String>{for (int i = 0; i < 500; i++) newId()};
      expect(ids.length, 500);
    });
  });
}
