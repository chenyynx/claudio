import 'package:ccpocket/features/generated_image_preview/generated_image_preview_item.dart';
import 'package:ccpocket/features/generated_image_preview/generated_image_preview_mapper.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const dataUrl =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
  const message = ToolResultMessage(
    toolUseId: 'image-generation-1',
    toolName: 'ImageGeneration',
    content: 'status: completed\nrevisedPrompt: Cached prompt',
    images: [ImageRef(id: 'image-1', url: dataUrl, mimeType: 'image/png')],
  );

  test('resolves a data URL without an HTTP base URL', () {
    final items = generatedImageItemsFromToolResults([
      message,
    ], httpBaseUrl: null);

    expect(items, hasLength(1));
    expect(items.single.bytes, isNotEmpty);
    expect(items.single.url, isNull);
  });

  test('skips a relative image when an HTTP base URL is unavailable', () {
    const relativeMessage = ToolResultMessage(
      toolUseId: 'image-generation-relative',
      toolName: 'ImageGeneration',
      content: 'status: completed',
      images: [
        ImageRef(
          id: 'relative-image',
          url: '/images/generated.png',
          mimeType: 'image/png',
        ),
      ],
    );

    expect(
      generatedImageItemsFromToolResults([relativeMessage], httpBaseUrl: null),
      isEmpty,
    );
  });

  test('keeps the disk cache key stable when Bridge image URLs change', () {
    const firstMessage = ToolResultMessage(
      toolUseId: 'image-generation-stable',
      toolName: 'ImageGeneration',
      content:
          'status: completed\n'
          'revisedPrompt: Stable image\n'
          'Generated 1 image',
      images: [
        ImageRef(
          id: 'bridge-image-1',
          url: '/images/random-1',
          mimeType: 'image/png',
          thumbnailUrl: '/images/random-1?variant=thumbnail',
        ),
      ],
    );
    const restoredMessage = ToolResultMessage(
      toolUseId: 'image-generation-stable',
      toolName: 'ImageGeneration',
      content: 'status: completed\nrevisedPrompt: Stable image',
      images: [
        ImageRef(
          id: 'bridge-image-2',
          url: '/images/random-2',
          mimeType: 'image/png',
          thumbnailUrl: '/images/random-2?variant=thumbnail',
        ),
      ],
    );

    final first = generatedImageItemsFromToolResults([
      firstMessage,
    ], httpBaseUrl: 'http://localhost:8765').single;
    final restored = generatedImageItemsFromToolResults([
      restoredMessage,
    ], httpBaseUrl: 'http://localhost:8765').single;

    expect(first.url, isNot(restored.url));
    expect(first.cacheKey, isNotNull);
    expect(first.cacheKey, restored.cacheKey);
    expect(
      first.chatImageUrl,
      'http://localhost:8765/images/random-1?variant=thumbnail',
    );
    expect(first.thumbnailCacheKey, '${first.cacheKey}-thumbnail-v1');
  });

  test('uses the original URL when an older Bridge omits thumbnailUrl', () {
    const legacyMessage = ToolResultMessage(
      toolUseId: 'image-generation-legacy',
      toolName: 'ImageGeneration',
      content: 'Generated 1 image',
      images: [
        ImageRef(
          id: 'legacy-image',
          url: '/images/legacy-image',
          mimeType: 'image/png',
        ),
      ],
    );

    final item = generatedImageItemsFromToolResults([
      legacyMessage,
    ], httpBaseUrl: 'http://localhost:8765').single;

    expect(item.thumbnailUrl, isNull);
    expect(item.chatImageUrl, item.url);
    expect(item.thumbnailCacheKey, item.cacheKey);
  });

  test('does not modify external image URLs without thumbnailUrl', () {
    const remoteMessage = ToolResultMessage(
      toolUseId: 'image-generation-remote',
      toolName: 'ImageGeneration',
      content: 'Generated 1 image',
      images: [
        ImageRef(
          id: 'remote-image',
          url: 'https://cdn.example.com/images/generated.png?signature=a%2Fb',
          mimeType: 'image/png',
        ),
      ],
    );

    final item = generatedImageItemsFromToolResults([
      remoteMessage,
    ], httpBaseUrl: null).single;

    expect(item.thumbnailUrl, isNull);
    expect(
      item.chatImageUrl,
      'https://cdn.example.com/images/generated.png?signature=a%2Fb',
    );
    expect(item.thumbnailCacheKey, item.cacheKey);
  });

  test(
    'changes the disk cache key when content-addressed image id changes',
    () {
      const firstMessage = ToolResultMessage(
        toolUseId: 'image-generation-content-addressed',
        toolName: 'ImageGeneration',
        content: 'Generated 1 image',
        images: [
          ImageRef(
            id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            url: '/images/first',
            mimeType: 'image/png',
          ),
        ],
      );
      const changedMessage = ToolResultMessage(
        toolUseId: 'image-generation-content-addressed',
        toolName: 'ImageGeneration',
        content: 'Generated 1 image',
        images: [
          ImageRef(
            id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            url: '/images/second',
            mimeType: 'image/png',
          ),
        ],
      );

      final first = generatedImageItemsFromToolResults([
        firstMessage,
      ], httpBaseUrl: 'http://localhost:8765').single;
      final changed = generatedImageItemsFromToolResults([
        changedMessage,
      ], httpBaseUrl: 'http://localhost:8765').single;

      expect(first.cacheKey, isNot(changed.cacheKey));
    },
  );

  test('reuses decoded data images from the supplied bounded cache', () {
    final cache = <GeneratedImageItemCacheKey, GeneratedImagePreviewItem>{};

    final first = generatedImageItemsFromToolResults(
      [message],
      httpBaseUrl: null,
      itemCache: cache,
    );
    final second = generatedImageItemsFromToolResults(
      [message],
      httpBaseUrl: null,
      itemCache: cache,
    );

    expect(cache, hasLength(1));
    expect(identical(first.single, second.single), isTrue);
    expect(identical(first.single.bytes, second.single.bytes), isTrue);
  });
}
