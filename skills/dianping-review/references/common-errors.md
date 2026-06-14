# Dianping Review: Common Errors Quick Reference

Quick-match error signatures from real sessions. If you hit one of these, the fix is documented.

## Error 1: `Argument list too long` on macOS

**Symptom**:
```
OSError: [Errno 7] Argument list too long: 'curl'
```

**Cause**: Base64-encoded image embedded directly in a `subprocess.run(...)` curl command string. macOS `ARG_MAX` is ~256KB; encoded images easily exceed this even after resize.

**Fix**: Write the JSON payload to a temp file, use `curl -d @file`:
```bash
python3 -c "json.dump(payload, open('/tmp/payload-N.json','w'))"
curl -s --max-time 180 ... -d @/tmp/payload-N.json
```

## Error 2: Vision model returns empty content (DeepSeek API)

**Symptom**:
```
Content length: 0
Reasoning length: 1051
```
The response has `reasoning_content` but empty `content`. The model spent all `max_tokens` on internal reasoning.

**Cause**: DeepSeek-compatible models (qwen3.6-35b via llama-server) count reasoning tokens against `max_tokens`. With `max_tokens=500`, complex image analysis exhausts the budget before outputting content.

**Fix**: 
1. Set `max_tokens` to 1200+ for vision tasks
2. Parse `reasoning_content` as a fallback if content is empty
3. Use shorter prompts on retry to leave more budget for content

## Error 3: Receipt is 点单 (order ticket) not 结账单 (payment receipt)

**Symptom**: Receipt image shows dish names, quantities, table number, time — but no prices or totals.

**Identification**: Look for headers like "点单" (not "结账单" or "小票"). Individual prices are typically absent. The receipt may have dish categories (特色小菜, 独特海鲜, etc.) and portion sizes (份, 中份, 小份) without corresponding prices.

**Fix**: Note in the review that prices are unavailable due to receipt type. Don't fabricate. Suggest manual price addition before publishing.

## Error 4: Image analysis prioritized over voice note

**Symptom**: The review focuses heavily on dishes visible in photos but barely mentions dishes the user discussed in the voice note. Or the review's tone contradicts the user's expressed opinion (user said "一般" but review says "不错").

**Cause**: Agent processes images first (visually rich, more tokens) and treats voice as supplementary context, when the reverse is correct — voice is the primary source of truth.

**Fix**: 
1. Restructure Step 2c — voice MUST be the first section in structured analysis, with images as a separate "补充信息" section
2. Re-draft with voice dishes first, user's actual opinions preserved verbatim
3. Image-only dishes get brief mentions without subjective scores
4. If voice and image analysis conflict → **voice wins unconditionally**

## Error 5: Fabricated details (杜撰)

**Symptom**: Review contains a price, dish name, or flavor description that has NO source in either voice transcript or image analysis. Common forms:
- Writing "人均80" when no price information exists anywhere
- Inventing a dish name because "this type of restaurant usually serves X"
- Upgrading user's "还行" to "味道惊艳，回味无穷"
- Describing a dish's texture/aroma that wasn't visible in images

**Cause**: LLM "helpfully" fills in gaps — guessing prices from dish type, inventing flavor notes that sound plausible, or elevating user sentiment to make the review more engaging.

**Fix**: 
1. Cross-check EVERY factual claim against the Step 2c structured analysis
2. If analysis says "价格未知", review MUST say "价格未知" (or omit price entirely)
3. If a dish appears only in images (not voice), it gets NO subjective score
4. Use explicit truthfulness markers: "看起来像是..." for image-based guesses
5. If Step 4 reviewer finds fabrication → **hard fail**, go back to Step 3 for re-draft (not just refinement)

## Error 7: faster-whisper fails with SOCKS proxy error

**Symptom**:
```
ImportError: Using SOCKS proxy, but the 'socksio' package is not installed.
Make sure to install httpx using `pip install httpx[socks]`.
```

**Cause**: Corporate network proxy (SOCKS) configured via environment variables. The `httpx` library used by `huggingface_hub` detects the proxy but lacks the `socksio` package to connect through it.

**Fix**: `pip3 install socksio`

Then retry the whisper transcription. The model download from HuggingFace will go through the proxy.

## Error 8: pip install ctranslate2 hangs indefinitely

**Symptom**: `pip3 install ctranslate2` runs for 120s+ with no output, then times out.

**Cause**: Without `--only-binary`, pip tries to compile ctranslate2 from source (C++ code). On slow machines or with old compilers, this takes forever.

**Fix**: Always use `pip3 install --only-binary :all: ctranslate2 tokenizers tqdm` to get the pre-compiled wheel. See `references/whisper-fallback.md` for full dependency chain.

## Error 9: HuggingFace model download fails with SSL EOF

**Symptom**:
```
httpx.ConnectError: EOF occurred in violation of protocol (_ssl.c:1129)
huggingface_hub.errors.LocalEntryNotFoundError: ... Cannot find the appropriate snapshot folder
```

**Cause**: Corporate HTTP proxy performs SSL inspection (man-in-the-middle). Python's SSL library doesn't trust the proxy's certificate, causing HTTPS connections to HuggingFace to terminate.

**Also fails**: `NO_PROXY=huggingface.co` bypass (corporate firewall blocks direct outbound). `curl -k` (same block). Monkey-patching `httpx verify=False` (error is at httpcore level, not httpx level).

**Fix**: Whisper model download is network-blocked. Follow the full fallback procedure in `references/whisper-fallback.md`. Key actions:
1. Stop attempting downloads (each attempt wastes 2-5 min)
2. Skip transcription, use image data only
3. Mark all subjective scores "待用户补充"
4. To recover: download model on a different network, or use OpenAI Whisper API, or have user manually provide the voice content

## Error 10: Whisper transcription unavailable — pipeline still runs

**Symptom**: All installation and download attempts fail, but the user wants a review.

**Behavior**: The pipeline CAN proceed without audio. The quality review sub-agent will correctly identify the gap and score accordingly (authenticity high, vividness/usefulness lower). The review will be factually complete (prices, dish names, environment) from images/receipts/APP screenshots, with subjective scores marked "待补充".

**This is NOT an error** — it's a designed fallback path. The `.reviewed` marker can be deleted later to re-generate with audio once whisper is available.

## Error 6: Culinary knowledge forced / encyclopedia dump of food trivia that breaks the reading flow and feels copy-pasted from Baidu Baike.

**Cause**: Agent dumps the entire web search result from Step 2.5 instead of distilling it to 1-2 sentences and weaving it naturally into the user's experience.

**Fix**: 
1. Use ONLY 1 interesting fact, not a paragraph
2. Tie it directly to the user's experience: "你提到的酸菜鱼酸得冲——据了解，传统酸菜发酵要20天以上，速成的才会有这种尖锐的酸"
3. If no natural insertion point exists → skip the culinary fact entirely (better to skip than force)

## Error 11: Review uses "听你说" / "据了解" distance markers

**Symptom**: Review reads like an interview transcript — "听你说清远鸡不错" "据了解春笋老了会涩口" "用户表示性价比一般" — when it should read as the writer's own dining experience.

**Cause**: Agent treats voice note as interview material rather than the writer's own memory.

**Fix**: 
1. Voice content IS the writer's experience — all opinions expressed directly: "清远鸡表现不错，鸡肉鲜嫩" NOT "听你说清远鸡不错"
2. Culinary knowledge expressed as personal expertise: "春笋季末的笋纤维变粗，口感会发涩" NOT "据了解春笋老了会涩口"
3. If a fact can't be expressed naturally as the writer's own knowledge → skip it
4. Verify: read the review aloud — does it sound like one person's authentic experience, or a research assistant's report?

## Error 12: ai-todo note has meta-commentary, not copy-paste ready

**Symptom**: Note body contains "零杜撰" "📊 质量评估 具体性4 生动性3..." "📁 /Volumes/..." — generation artifacts that require manual deletion before publishing to 大众点评.

**Cause**: Agent treats ai-todo note as an internal work log, not the publishing-ready output.

**Fix**: 
1. Note body = review text + tags ONLY
2. All quality scores, file paths, iteration counts → `review.md` only, never in note
3. After writing, verify: select all → copy → paste to 大众点评 → publish with ZERO edits
4. If any line would look weird to a 大众点评 reader, remove it before creating the note

## Error 13: ai-todo note has only headline, missing review body

**Symptom**: The `ai-todo notes:create` succeeded but the note only contains the `【点评】<餐厅名> ...` headline. The full review text (dish details, environment, summary, tags) is missing.

**Cause**: Agent puts the headline in `--title` and expects a separate `--description` field for the body. But `ai-todo notes:create` only has `--title` and `--tags` — there is no `--description` flag.

**Fix**: The ENTIRE review text (headline + body + tags) must go in `--title`. This includes:
1. The headline line
2. All dish details
3. Environment/service
4. Summary
5. Tags

The `--title` field accepts multi-line text with `\n` newlines. Use a single `--title` argument containing the complete review.

**Verification**: After creating the note, run `ai-todo notes:list` and check the note's `title` field. It must contain the complete review, not just the headline.
