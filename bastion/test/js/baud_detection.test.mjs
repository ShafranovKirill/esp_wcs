import test from "node:test"
import assert from "node:assert/strict"
import {assessSample} from "../../assets/js/hooks/baud_detection.js"
const encode = value => [...new TextEncoder().encode(value)]

test("detects a real prompt and strips ANSI", () => {
  assert.equal(assessSample(encode("\x1b[32mUser Name:\x1b[0m\r\n")).sample, "User Name:\r\n")
  assert.ok(assessSample(encode("Добро пожаловать\r\n")))
})

test("silence, repeated characters, invalid bytes and binary output give no candidate", () => {
  for (const sample of [[], encode("\r\n"), encode("xxxxxxxxxxxxxxxx"), [255,254,253,252,251,250,249,248], [0,0,0,0,65,66,67,68,69,70]]) {
    assert.equal(assessSample(sample), null)
  }
})
