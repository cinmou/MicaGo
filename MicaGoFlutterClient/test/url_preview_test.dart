import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/url_preview.dart';

void main() {
  test('urlsInText returns every normalized URL in the message', () {
    final urls = urlsInText('one https://a.example, two www.b.example!');

    expect(urls, ['https://a.example', 'https://www.b.example']);
    expect(firstUrlInText('one https://a.example two'), 'https://a.example');
  });
}
