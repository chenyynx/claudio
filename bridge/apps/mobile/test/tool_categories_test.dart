import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/utils/tool_categories.dart';

void main() {
  group('getToolFullInput', () {
    test('bash: returns full command string', () {
      final result = getToolFullInput(ToolCategory.bash, {
        'command': 'git add README.md README.ja.md apps/mobile/fastlane/metadata/en-US/description.txt',
      });
      expect(
        result,
        'git add README.md README.ja.md apps/mobile/fastlane/metadata/en-US/description.txt',
      );
    });

    test('bash: returns multiline command as-is', () {
      final cmd =
          'find /Users/project -name "*.dart" -not -path "*/build/*" | xargs grep -l "ToolUseTile" | sort | head -20';
      final result = getToolFullInput(ToolCategory.bash, {'command': cmd});
      expect(result, cmd);
    });

    test('bash: falls back to JSON when no command key', () {
      final result = getToolFullInput(ToolCategory.bash, {'foo': 'bar'});
      expect(result, contains('"foo"'));
    });

    test('search: returns pattern with path and glob', () {
      final result = getToolFullInput(ToolCategory.search, {
        'pattern': 'class\\s+ToolUseTile',
        'path': '/Users/project/apps/mobile/lib',
        'glob': '**/*.dart',
      });
      expect(result, contains('class\\s+ToolUseTile'));
      expect(result, contains('/Users/project/apps/mobile/lib'));
      expect(result, contains('**/*.dart'));
    });

    test('search: returns pattern only when no other fields', () {
      final result = getToolFullInput(ToolCategory.search, {
        'pattern': 'searchTerm',
      });
      expect(result, contains('searchTerm'));
    });

    test('read: returns full file path', () {
      final result = getToolFullInput(ToolCategory.read, {
        'file_path': '/Users/project/apps/mobile/lib/widgets/bubbles/assistant_bubble.dart',
      });
      expect(
        result,
        '/Users/project/apps/mobile/lib/widgets/bubbles/assistant_bubble.dart',
      );
    });

    test('write: returns full file path', () {
      final result = getToolFullInput(ToolCategory.write, {
        'file_path': '/Users/project/lib/main.dart',
      });
      expect(result, '/Users/project/lib/main.dart');
    });

    test('other: formats key-value pairs', () {
      final result = getToolFullInput(ToolCategory.other, {
        'description': 'Run the tests',
        'prompt': 'Check all files',
      });
      expect(result, contains('description'));
      expect(result, contains('Run the tests'));
    });

    test('fallback: returns JSON for empty input', () {
      final result = getToolFullInput(ToolCategory.other, {});
      expect(result, '{}');
    });
  });
}
