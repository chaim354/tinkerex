// Save an addon's output, asking first when the host says the write would REPLACE something.
//
// WHY THIS EXISTS. An addon save writes into a folder that defaults to the current project's, and
// the host then files each output into a category subfolder (`design/`, `models/`, …). Re-saving
// under the same name used to slip between two collision checks that look at different folders: the
// host's door checked the folder you picked, which is vacant because the first copy has already
// been filed, so the save was accepted — and the sweep then could not place it, leaving a SECOND
// copy stranded at the project root forever, silently. See tinkerex CLAUDE.md §12 item 11.
//
// THE HOST NOW ANSWERS 409 BEFORE WRITING ANYTHING:
//
//   { "error": "would_replace", "files": [ { "name": "harbor-number-v4.svg", "folder": "design" } ] }
//
// Resending the same body with `overwrite=1` replaces exactly those files IN PLACE — the host keeps
// each one's node, so every project attachment, BOM link and tag pointing at it survives. Anything
// else non-ok is an ordinary failure and is handed straight back.
//
// 409 IS NOT 422. The host also answers 422 (`unsupported_operation`) for "that name is taken in
// the folder you picked", which never succeeds on retry and must NOT prompt. Only 409 is a
// question. Branching on the status alone would offer an Overwrite button for a save that can never
// take one.
//
// `confirmFn` IS INJECTED so a test can answer without a live dialog; it defaults to the browser's
// own confirm. Declining is reported separately from failing — `res.ok` is false either way, and
// "Save failed." is the wrong thing to tell someone who just clicked Cancel.
export async function saveWithOverwrite(url, body, csrfToken, confirmFn = window.confirm) {
  const post = () => fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": csrfToken } })

  const res = await post()
  if (res.status !== 409) return { res, cancelled: false }

  // A 409 whose body is not the shape we know is not ours to interpret — hand it back as a failure
  // rather than prompting about something we cannot name.
  let payload = null
  try {
    payload = await res.json()
  } catch {
    return { res, cancelled: false }
  }
  if (payload?.error !== "would_replace" || !payload.files?.length) return { res, cancelled: false }

  const lines = payload.files.map((f) => `  ${f.name}  (in ${f.folder}/)`).join("\n")
  const ok = confirmFn(
    `This will replace ${payload.files.length === 1 ? "a file" : "files"} you already saved:\n\n` +
      `${lines}\n\nReplace with this version?`,
  )
  if (!ok) return { res, cancelled: true }

  body.append("overwrite", "1")
  return { res: await post(), cancelled: false }
}
