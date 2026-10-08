# Inline bilingual EPUB mode

This build keeps the upstream KoTranslate provider system and adds two Chinese menu actions:

- 翻译当前章节（生成双语 EPUB）
- 翻译整本书（生成双语 EPUB）

The translated paragraph is inserted immediately after its source paragraph in a new EPUB. Its font size is entered as a percentage (50%–200%), and its color has nine grayscale choices from 10% to 90% gray. The default provider is MyMemory because the Kindle cannot reach KOReader's built-in Google endpoint in the current network.
