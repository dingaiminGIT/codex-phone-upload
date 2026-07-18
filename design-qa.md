# Mobile Queue Design QA

- Source truth: `/Users/dingaimin/.codex/generated_images/019f751a-7243-7df2-9598-95a20746a574/exec-0f48e771-c11d-46c7-985d-cc226cc2db3b.png`
- Implementation capture: `/tmp/codex-phone-upload-queue-zh-final.png`
- Combined comparison: `/tmp/codex-phone-upload-design-compare-initial.png`
- Viewport: 390 × 844 CSS pixels
- State: Simplified Chinese, target task visible, six selected images

## Full-view comparison

The first combined comparison used the source and implementation at the same 390 × 844 viewport. The overall hierarchy, spacing system, target-task confirmation, six-row queue, bilingual switch, trust copy, limits, and restrained blue/green/gray palette matched the selected direction.

## Findings and iteration

1. **P1 — Primary upload button below the first viewport.** The initial implementation used 88 px queue rows and reserved an empty status block, so the upload button was not visible with six selected images.
2. **Fix applied.** Queue rows were reduced to 66 px, thumbnails to 48 px, the target block to 58 px, outer and section spacing were tightened, and the status block now occupies space only when it contains a message. The computed reduction is 241 px, bringing the six-image page from 1065 px to approximately 824 px.
3. **P3 — Source uses iconography while the implementation uses text actions.** This is intentional: the project has no icon library or source icon assets, and text controls keep the offline page lightweight and accessible without approximated glyphs.
4. **P3 — QA fixture thumbnails are solid-color images.** Real uploads use the selected image object URLs and display actual thumbnails; the `?preview=queue` fixture is disabled and exists only for deterministic layout checks.

## Focused-region evidence

The full-height mobile screen already contains the complete target, queue, notice, primary action, and limits. No separate focused-region comparison was needed.

## Final result

blocked

The post-fix browser recapture was blocked by the in-app browser URL security policy after the LAN session changed. Build tests and the deterministic layout changes passed, but the final same-state visual screenshot still needs one manual phone/browser check before this QA can be marked passed.
