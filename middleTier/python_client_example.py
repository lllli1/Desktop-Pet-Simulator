import asyncio, json, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:8010/python/ws") as ws:
        print("Python mock connected to bridge.")
        while True:
            raw = await ws.recv()
            print("<= from bridge:", raw)
asyncio.run(main())
