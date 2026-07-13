# KWS model — sherpa-onnx-kws-zipformer-gigaspeech

The on-device keyword spotter loads its model from this directory. The binaries
are **large and not committed** — fetch them before a device build. On launch
[KwsAssetExtractor](../../../lib/capture/kws_asset_extractor.dart) copies these to
`<appDocuments>/kws/` so sherpa can open them as files.

## Files (real release names — the single source of truth is `KwsAssetExtractor`)

```
encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx
decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx
joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx
tokens.txt
keywords.txt           # BPE-tokenized keyword list (see below) — YOU create this
keywords_reference.txt # the example keywords file from the download, reference only
```

Download `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01` from the
sherpa-onnx releases (https://github.com/k2-fsa/sherpa-onnx/releases) and drop the
`.onnx` files + `tokens.txt` here. Save the download's example keywords file as
`keywords_reference.txt` so the required token format is visible in the repo (it is
NOT extracted or used at runtime — only `keywords.txt` is).

## keywords.txt (BPE format — not plain strings)

sherpa's KeywordSpotter reads keywords as **space-separated BPE subword tokens**
with `▁` word-start markers, **not** the plain strings in
[keyword_config.dart](../../../lib/capture/keyword_config.dart). Until `keywords.txt`
holds correctly tokenized lines, **no keyword is ever spotted** — this is a hard
prerequisite for the on-device voice trigger.

One line per command; convert the seven phrases below by splitting each word into
its `tokens.txt` subwords. Match `keywords_reference.txt`'s format exactly:

```
log it · log scary · mark level one · mark level two · mark level three ·
mark level four · mark level five
```
Words to look up in `tokens.txt`: LOG, IT, SCARY, MARK, LEVEL, ONE, TWO, THREE,
FOUR, FIVE.

**Two ways to build it:**
- **(B) Manual — recommended for M1** (7 keywords): open `tokens.txt`, find each
  word's subword split, write the seven lines by hand.
- **(A) One-off script:** a Dart script that reads `tokens.txt` and greedily
  tokenizes the phrases → `keywords.txt`, run once and committed.

`keyword_config.dart` stays the source of truth for **severity + features**; that
mapping is separate from what sherpa needs to spot the phrase.
