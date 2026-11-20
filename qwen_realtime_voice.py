#!/usr/bin/env python3
import asyncio
import base64
import json
import os
import queue
import ssl
import threading

import certifi
import sounddevice as sd
import websockets

API_KEY = os.environ.get("TOKEN_PLAN_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")
if not API_KEY:
  raise SystemExit("Token Plan API Key not found. Configure it in the Agent tool first.")
WS_URL = "wss://token-plan.maas.qianwenaiapi.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus"

play_queue = queue.Queue()


def play_audio():
  with sd.RawOutputStream(samplerate=24000, channels=1, dtype="int16") as stream:
    while True:
      chunk = play_queue.get()
      if chunk is None:
        break
      stream.write(chunk)


async def receive(ws):
  transcript = []
  async for message in ws:
    event = json.loads(message)
    event_type = event["type"]
    if event_type == "conversation.item.input_audio_transcription.completed":
      print(f"\n[你说] {event.get('transcript', '')}", flush=True)
    elif event_type == "response.audio.delta":
      play_queue.put(base64.b64decode(event["delta"]))
    elif event_type == "response.audio_transcript.delta":
      transcript.append(event.get("delta", ""))
    elif event_type == "response.audio_transcript.done":
      print(f"[AI] {''.join(transcript)}", flush=True)
      transcript.clear()
    elif event_type == "error":
      print(f"[错误] {event}", flush=True)


async def send_mic(ws):
  loop = asyncio.get_running_loop()
  audio_queue = asyncio.Queue()

  def callback(indata, frames, time_info, status):
    loop.call_soon_threadsafe(audio_queue.put_nowait, bytes(indata))

  with sd.RawInputStream(
    samplerate=16000,
    channels=1,
    dtype="int16",
    blocksize=1600,
    callback=callback,
  ):
    print("开始说话，按 Ctrl+C 结束。", flush=True)
    while True:
      chunk = await audio_queue.get()
      await ws.send(
        json.dumps(
          {
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(chunk).decode(),
          }
        )
      )


async def main():
  context = ssl.create_default_context(cafile=certifi.where())
  async with websockets.connect(
    WS_URL,
    ssl=context,
    additional_headers={"Authorization": f"Bearer {API_KEY}"},
    max_size=None,
  ) as ws:
    await ws.recv()
    await ws.send(
      json.dumps(
        {
          "type": "session.update",
          "session": {
            "modalities": ["audio", "text"],
            "voice": "longanqian",
            "instructions": "你是语音助手，回答简洁自然。",
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
            "turn_detection": {
              "type": "server_vad",
              "threshold": 0.5,
              "silence_duration_ms": 600,
            },
          },
        }
      )
    )
    threading.Thread(target=play_audio, daemon=True).start()
    await asyncio.gather(receive(ws), send_mic(ws))


if __name__ == "__main__":
  try:
    asyncio.run(main())
  except KeyboardInterrupt:
    pass
  finally:
    play_queue.put(None)
