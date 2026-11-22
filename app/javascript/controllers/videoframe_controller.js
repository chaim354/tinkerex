import { Controller } from "@hotwired/stimulus"

// "USE THIS FRAME AS PREVIEW" (2026-11-22): the frame the player shows becomes the file's grid
// tile. Nothing on the server can decode a video (Debian's ffmpeg is a GPL build, CLAUDE.md §9), so
// the browser that is already playing it draws the frame into a canvas, encodes a PNG and posts it
// to Files::PreviewsController — the door the 3D viewer's "Use this view as preview" uses, which
// stores it as a `viewer` row, `ready`, at the file's current content.
//
// THE LONGEST SIDE IS AT MOST 512, AND A SMALLER FRAME IS NOT BLOWN UP. 512 is what the 3D viewer
// saves and is half the door's MAX_SIDE (1024); a 160x90 clip upscaled would only be a larger file
// holding the same pixels, which the tile's own scaling draws just as well.
const PREVIEW_SIDE = 512

// How long one wait on a player — for its metadata, a seek, the twin's first frame — may take
// before the capture gives up. The twin (below) fetches the metadata and the frame's range again,
// which measured under a second against a local SeaweedFS; a slow store should still say something
// rather than leave "Saving…" up for good.
const WAIT_MS = 20000

// The twin could not be read: the store refused this origin (no CORS rule for it), or it never
// loaded. A class of its own, so the message can name the one cause an operator can act on.
class StoreRefused extends Error {}

// The player painted nothing into the canvas (framePng), which no seek put right.
class NoPicture extends Error {}

export default class extends Controller {
  static targets = ["video", "status"]
  static values = { previewUrl: String }

  disconnect() {
    this.releaseTwin()
  }

  // ON SHARE AND CHUNK_REMOTE THE PLAYER IS SAME-ORIGIN, so its own frame is drawn and nothing is
  // fetched again. ON S3 IT IS NOT: the byte route answers a 302 to a presigned bucket URL, and a
  // frame drawn from a cross-origin <video> TAINTS the canvas, and reading it throws SecurityError
  // (measured, 2026-11-22). The player itself must NOT be `crossorigin="anonymous"` to avoid that:
  // against a bucket whose CORS rule does not list this origin, a crossorigin element does not play
  // at all (MEDIA_ERR_SRC_NOT_SUPPORTED, measured), where a plain one plays fine — and DEPLOY.md's
  // promise is that a missing CORS rule degrades a viewer, never breaks one. So only on a taint does
  // the capture load a SECOND, crossorigin element at the same position, which the bucket's CORS rule
  // (DEPLOY.md, the rule the 3D viewer already needs) makes readable, and says so when it is not.
  async capture(event) {
    const button = event?.currentTarget
    if (!this.previewUrlValue || !this.hasVideoTarget) return
    if (button) button.disabled = true
    this.say("Saving preview…")
    try {
      const video = this.videoTarget
      await frameReady(video)
      const blob = await framePng(video).catch(async (error) => {
        if (error?.name !== "SecurityError") throw error
        return framePng(await this.readableTwin(video))
      })
      const body = new FormData()
      body.append("image", blob, "preview.png")
      const response = await fetch(this.previewUrlValue, {
        method: "POST",
        body,
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
        }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.say("Saved this frame as the preview.")
    } catch (error) {
      console.warn("[videoframe] could not save the frame:", error)
      if (error instanceof StoreRefused) {
        this.say("Couldn't read this frame: the bucket holding the video has no CORS rule for this site.")
      } else if (error instanceof NoPicture) {
        this.say("The player showed no picture to save. Play or seek the video, then try again.")
      } else {
        this.say("Couldn't save the preview.")
      }
    } finally {
      this.releaseTwin()
      if (button) button.disabled = false
    }
  }

  // A crossorigin copy of the player, seeked to the player's position, for a canvas to read. It is
  // never attached to the page, and it is released after every capture, so a long video's buffer is
  // not held for the life of the page.
  async readableTwin(video) {
    this.releaseTwin()
    const twin = document.createElement("video")
    this.twin = twin
    twin.crossOrigin = "anonymous"
    twin.muted = true
    twin.playsInline = true
    twin.preload = "auto"
    try {
      const loaded = nextEvent(twin, "loadeddata")
      twin.src = video.currentSrc || video.src
      await loaded
      // A seek runs even to the position the element is already at, so `seeked` comes at 0 too.
      const seeked = nextEvent(twin, "seeked")
      twin.currentTime = video.currentTime
      await seeked
    } catch (error) {
      throw new StoreRefused(error.message)
    }
    return twin
  }

  releaseTwin() {
    if (!this.twin) return
    this.twin.removeAttribute("src")
    this.twin.load()
    this.twin = null
  }

  say(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}

// A PAUSED PLAYER IS SEEKED TO WHERE IT ALREADY IS, EVERY TIME, AND `readyState` IS NOT TRUSTED TO
// SKIP IT. A paused element can report HAVE_ENOUGH_DATA while holding no decoded picture — measured
// (2026-11-22): Chrome, a tab not on screen, a 160x90 webm at 0 s — and drawImage then paints
// nothing and taints nothing, so a transparent PNG went out as the preview. A seek decodes exactly
// the frame at that position; it is what made the never-attached twin below drawable too. It waits
// for the metadata first: before it, setting currentTime only records a start position, and at 0 no
// seek ever runs. A PLAYING element is decoding the frame on screen and is drawn as it is.
//
// AN ELEMENT HOLDING NOTHING IS ASKED TO LOAD, or the wait for its metadata never ends: one whose
// preload is "none" — what iOS Safari treats every element as — waits for a play or a seek before it
// fetches a byte. `load()` under preload "auto" is that request, made before this function's first
// await, so it is still inside the click that iOS requires. The position it resets was 0 anyway.
async function frameReady(video) {
  if (video.readyState === HTMLMediaElement.HAVE_NOTHING) {
    video.preload = "auto"
    video.load()
  }
  if (video.readyState < HTMLMediaElement.HAVE_METADATA) await nextEvent(video, "loadedmetadata")
  if (!video.paused) return
  const seeked = nextEvent(video, "seeked")
  video.currentTime = video.currentTime
  await seeked
}

// The element's next `name` event, or a rejection on its `error` or after WAIT_MS.
function nextEvent(element, name) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => done(reject, new Error(`no ${name} from the player`)), WAIT_MS)
    const onEvent = () => done(resolve)
    const onError = () => done(reject, new Error(`player error ${element.error?.code}`))
    function done(settle, value) {
      clearTimeout(timer)
      element.removeEventListener(name, onEvent)
      element.removeEventListener("error", onError)
      settle(value)
    }
    element.addEventListener(name, onEvent)
    element.addEventListener("error", onError)
  })
}

// The element's current frame as a PNG.
//
// THE PIXELS ARE READ BEFORE THE ENCODE, FOR TWO ANSWERS. A tainted canvas throws SecurityError
// from getImageData (synchronously, as toBlob would), which rejects with that error unchanged for
// capture() to recognise. And a canvas the element painted nothing into — every pixel's alpha 0,
// where a video frame is opaque — is refused rather than encoded: frameReady's seek is what should
// make that unreachable, and this is what keeps an invisible tile from being saved if it is not.
// The scan is at most 512x512. EXPORTED for test/system/video_frame_test.rb, which hands it an
// element holding no frame: the one way to reach the refusal on demand.
export function framePng(video) {
  return new Promise((resolve, reject) => {
    try {
      const scale = Math.min(1, PREVIEW_SIDE / Math.max(video.videoWidth, video.videoHeight))
      const canvas = document.createElement("canvas")
      canvas.width = Math.max(1, Math.round(video.videoWidth * scale))
      canvas.height = Math.max(1, Math.round(video.videoHeight * scale))
      const context = canvas.getContext("2d")
      context.drawImage(video, 0, 0, canvas.width, canvas.height)
      if (!painted(context.getImageData(0, 0, canvas.width, canvas.height).data)) {
        throw new NoPicture("the player drew no picture")
      }
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("the frame did not encode"))), "image/png")
    } catch (error) {
      reject(error)
    }
  })
}

// Whether any pixel has any opacity (RGBA bytes; alpha is every fourth).
function painted(rgba) {
  for (let i = 3; i < rgba.length; i += 4) if (rgba[i] !== 0) return true
  return false
}
