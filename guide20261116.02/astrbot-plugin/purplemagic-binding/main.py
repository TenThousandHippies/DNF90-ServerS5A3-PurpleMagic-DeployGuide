"""PurpleMagic QQ 账号绑定（AstrBot 插件）。

玩家在登录器获取六位绑定码后，在允许群 @机器人 发送：/绑定 123456
插件调用 DNF 服务器网关的 /api/bot/qq-binding/* 接口完成绑定。

配置项（插件设置里填）：
  endpoint: 隧道地址，默认 http://127.0.0.1:18782
  token   : 与 DNF 服务器 gateway.json 的 qq_bot_token 一致
"""
import aiohttp

from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import Context, Star, register


@register("purplemagic-binding", "PurpleMagic", "PurpleMagic QQ 账号绑定", "1.0.0")
class PurpleMagicBinding(Star):
    def __init__(self, context: Context, config: dict = None):
        super().__init__(context)
        cfg = config or {}
        self.endpoint = (cfg.get("endpoint") or "http://127.0.0.1:18782").rstrip("/")
        self.token = cfg.get("token") or ""

    async def _call(self, method: str, path: str, payload: dict | None = None):
        headers = {"Authorization": f"Bearer {self.token}"}
        url = f"{self.endpoint}/api/bot/qq-binding/{path}"
        async with aiohttp.ClientSession() as session:
            async with session.request(method, url, json=payload, headers=headers, timeout=10) as resp:
                body = await resp.json(content_type=None)
                if resp.status >= 400 or body.get("ok") is False:
                    raise RuntimeError(body.get("message") or "绑定服务暂不可用")
                # gateway 成功时返回 {"ok": true, "data": {...}}
                return body.get("data", body)

    @filter.command("绑定")
    async def bind(self, event: AstrMessageEvent):
        parts = event.message_str.strip().split()
        code = parts[-1] if parts else ""
        if not (len(code) == 6 and code.isdigit()):
            yield event.plain_result("请在登录器获取六位绑定码，然后发送：/绑定 123456")
            return

        group = str(event.get_group_id() or "")
        qq = str(event.get_sender_id())
        if not group:
            yield event.plain_result("请在允许绑定的 QQ 群内 @机器人 发送绑定指令。")
            return

        try:
            cfg = await self._call("GET", "settings")
            if not (cfg.get("enabled") or cfg.get("allowBinding")):
                yield event.plain_result("当前服务器未启用 QQ 绑定。")
                return
            groups = [str(g) for g in cfg.get("groups") or []]
            if group not in groups:
                yield event.plain_result("当前群不在允许绑定列表，请联系管理员。")
                return
            await self._call("POST", "complete", {
                "code": code,
                "qq": qq,
                "group": group,
                "revision": cfg.get("revision", 0),
            })
            yield event.plain_result("绑定成功，现在可以返回 PurpleMagic 登录游戏。")
        except Exception as error:  # noqa: BLE001 - 统一给玩家短提示
            text = str(error).strip() or "绑定服务暂不可用，请稍后重试"
            yield event.plain_result(text[:160])
