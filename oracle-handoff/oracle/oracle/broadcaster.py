"""Bounded in-memory state broadcaster for authenticated SSE clients."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Set


class StateBroadcaster:
    """Publish complete snapshots without blocking the scan loop."""

    def __init__(self, queue_size: int = 8) -> None:
        self.queue_size = max(1, queue_size)
        self._queues: Set[asyncio.Queue[Any]] = set()

    @asynccontextmanager
    async def subscription(self) -> AsyncIterator[asyncio.Queue[Any]]:
        queue: asyncio.Queue[Any] = asyncio.Queue(maxsize=self.queue_size)
        self._queues.add(queue)
        try:
            yield queue
        finally:
            self._queues.discard(queue)

    async def publish(self, item: Any) -> None:
        for queue in tuple(self._queues):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(item)
            except asyncio.QueueFull:
                pass

    async def subscriber_count(self) -> int:
        return len(self._queues)
