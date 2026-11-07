export const DETECTION_BAUDS = [115200, 9600, 38400, 57600, 19200, 4800, 2400, 1200, 230400, 460800, 921600]

export function assessSample(bytes) {
  if (bytes.length < 8) return null
  let text
  try {
    text = new TextDecoder("utf-8", {fatal: true}).decode(Uint8Array.from(bytes))
  } catch {
    return null
  }
  text = text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
  const chars = Array.from(text)
  const readable = chars.filter(c => /[\p{L}\p{N}\p{P}\p{S}\p{Zs}\r\n\t]/u.test(c)).length
  const letters = chars.filter(c => /[\p{L}]/u.test(c)).length
  if (chars.length < 8 || letters < 4 || readable / chars.length < 0.95 || new Set(chars).size < 4) return null
  return {score: readable / chars.length, sample: text.slice(0, 512)}
}
