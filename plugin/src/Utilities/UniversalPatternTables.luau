--[[
	ForgePilot / Utilities / UniversalPatternTables
	Flat, alternation-free matching tables for provider error classification.

	WHY FLAT
	Every row is a single literal pattern and the FIRST match wins. There is no
	alternation `(a|b)`, no non-capturing group, and no character class containing
	multi-byte characters. That makes matching identical on every Lua-family
	runtime (including Roblox Studio and the headless test harness), keeps the
	tables trivial to extend, and makes each rule independently verifiable.

	Tables are evaluated in the order given by UniversalErrorDetector.GROUPS, so
	more specific categories are listed before general ones.
]]

local Tables = {}

local rateLimit: { string } = {
	-- English
	"rate limit",
	"rate_limit",
	"ratelimit",
	"too many requests",
	"requests per minute",
	"requests per second",
	"requests per hour",
	"requests per day",
	"request limit",
	"throttl",
	-- "quota exceeded" and "exceeded your current quota" are deliberately absent
	-- here: they map to QUOTA_WINDOW_EXHAUSTED, which is matched earlier.
	"slow down",
	-- Simplified Chinese
	"请求过于频繁",
	"请求频率超限",
	"已达到请求数限制",
	"达到请求数限制",
	"访问频率过高",
	"每分钟请求次数限制",
	"频率限制",
	"超出频率",
	"调用次数超限",
	"请求数限制",
	-- Traditional Chinese
	"請求過於頻繁",
	"請求頻率超限",
	"已達到請求數限制",
	"訪問頻率過高",
	"頻率限制",
	-- Japanese
	"レート制限",
	"リクエストが多すぎ",
	"頻度制限",
	"アクセスが集中",
	"多すぎるリクエスト",
	-- Korean
	"요청 한도",
	"요청이 너무 많",
	"호출 한도",
	"속도 제한",
	"요청 제한",
	-- Indonesian
	"terlalu banyak permintaan",
	"batas permintaan",
	"permintaan melebihi",
	"batas laju",
	-- Spanish
	"demasiadas solicitudes",
	"demasiadas peticiones",
	"límite de solicitudes",
	"límite de peticiones",
	"excede el límite",
	"excede el limite",
	"límite alcanzado",
	"limite alcanzado",
	"solicitudes por minuto",
	"intente de nuevo más tarde",
	"intente de nuevo mas tarde",
}

local concurrency: { string } = {
	"concurrent",
	"too many concurrent",
	"并发请求数已达上限",
	"并发",
	"並行",
	"동시 요청",
	"permintaan bersamaan",
	"solicitudes simultáneas",
	"solicitudes simultaneas",
}

local overload: { string } = {
	"overloaded",
	"server is busy",
	"service unavailable",
	"temporarily unavailable",
	"try again later",
	"请稍后再试",
	"系统繁忙",
	"服务器繁忙",
	"服务暂时不可用",
	"系统繁忙中",
	"請稍後再試",
	"系統繁忙",
	"サーバーが混み",
	"一時的に利用できません",
	"일시적으로 이용",
	"서버가 바쁩니다",
	"sibuk",
	"no disponible",
	"sobrecargado",
}

local dailyQuota: { string } = {
	"daily quota",
	"daily limit",
	"quota exceeded for today",
	"quota exceeded for this day",
	"monthly quota",
	"monthly limit",
	"tokens per day",
	"月度额度",
	"每日额度",
	"每日限額",
	"月度額度",
	"月度配额",
	"每日配额",
	"每日请求次数限制",
	"使用了达到上限",
	"已达到使用上限",
	"使用量已达上限",
	"日額",
	"月額",
	"월간 한도",
	"일일 한도",
	"kuota harian",
	"cuota diaria",
	"cuota mensual",
}

local credits: { string } = {
	"insufficient_credit",
	"insufficient_credits",
	"insufficient credit",
	"insufficient credits",
	"insufficient_quota",
	"insufficient quota",
	"insufficient_balance",
	"insufficient balance",
	"insufficient funds",
	"payment required",
	"credit balance is too low",
	"额度已用完",
	"余额不足",
	"账户余额不足",
	"帳戶餘額不足",
	"余额已用尽",
	"餘額不足",
	"积分不足",
	"費用不足",
	"余额已耗尽",
	"残高不足",
	"크레딧 부족",
	"크레딧이 부족",
	"kredit tidak cukup",
	"kredit habis",
	"saldo insuficiente",
	"créditos insuficientes",
}

local auth: { string } = {
	"invalid_api_key",
	"invalid api key",
	"invalid-api-key",
	"incorrect api key",
	"api key not found",
	"api key missing",
	"api key expired",
	"api key revoked",
	"unauthorized",
	"authentication failed",
	"authentication error",
	"authentication required",
	"invalid_token",
	"invalid token",
	"密钥无效",
	"密钥错误",
	"无效的密钥",
	"无效的api key",
	"apikey无效",
	"身份验证失败",
	"認證失敗",
	"認証に失敗しました",
	"인증에 실패",
	"autentikasi gagal",
	"autenticación fallida",
	"no autorizado",
}

local model: { string } = {
	"model_not_found",
	"model not found",
	"unknown model",
	"model does not exist",
	"unsupported model",
	"model is deprecated",
	"model not supported",
	"invalid model",
	"does not exist",
	"模型不存在",
	"模型无效",
	"模型不支持",
	"找不到模型",
	"不支援模型",
	"モデルが存在しません",
	"無効なモデル",
	"サポートされていないモデル",
	"지원하지 않는 모델",
	"model tidak ditemukan",
	"model tidak dikenal",
	"modelo no encontrado",
	"modelo no existe",
}

local endpoint: { string } = {
	"no such endpoint",
	"no such route",
	"unknown endpoint",
	"unknown path",
	"unsupported endpoint",
	"endpoint not found",
	"method not allowed",
	"接口不存在",
	"接口未找到",
	"不支持接口",
	"エンドポイントがありません",
	"存在しないエンドポイント",
	"endpoint tidak ditemukan",
	"extremo no encontrado",
	"ruta no encontrada",
}

local request: { string } = {
	"invalid_request",
	"invalid request",
	"invalid_parameter",
	"invalid parameter",
	"invalid_json",
	"invalid json",
	"missing required parameter",
	"missing required field",
	"missing parameter",
	"value must be",
	"is not valid",
	"unprocessable entity",
	"请求无效",
	"请求参数错误",
	"参数错误",
	"無効なリクエスト",
	"잘못된 요청",
	"permintaan tidak valid",
	"solicitud no válida",
	"solicitud no valida",
}

local context: { string } = {
	"context_length",
	"context length",
	"maximum context",
	"too many tokens",
	"reduce the length",
	"prompt is too long",
	"上下文过长",
	"上下文超长",
	"上下文超出",
	"超出最大长度",
	"输入过长",
	"コンテキストが長すぎ",
	"コンテキスト長",
	"컨텍스트 초과",
	"컨텍스트가 너무",
	"konteks terlalu panjang",
	"contexto demasiado largo",
	"excede el contexto",
}

local unsupported: { string } = {
	"not supported",
	"unsupported parameter",
	"unsupported value",
	"unsupported feature",
	"unsupported operation",
	"does not support",
	"invalid_function_call",
	"invalid function call",
	"unrecognized request argument",
	"不支持的功能",
	"不支持的参数",
	"不支持的参数值",
	"不支持调用",
	"未知的参数",
	"未知参数",
	"サポートされていません",
	"サポートされていない",
	"지원하지 않습니다",
	"지원하지 않는",
	"tidak didukung",
	"no compatible con",
	"no compatible con",
	"no admite",
}

local attachment: { string } = {
	"invalid_file",
	"invalid file",
	"invalid_image",
	"invalid image",
	"invalid_audio",
	"invalid attachment",
	"unsupported file",
	"unsupported image",
	"unsupported media",
	"unsupported format",
	"file too large",
	"file too big",
	"mime type",
	"文件无效",
	"文件不支持",
	"文件过大",
	"图片无效",
	"图片不支持",
	"サポートされていないファイル",
	"サポートされていない形式",
	"지원하지 않는 파일",
	"berkas tidak didukung",
	"archivo no compatible",
	"imagen no compatible",
}

local filter: { string } = {
	"content_filter",
	"content filter",
	"content_policy",
	"content policy",
	"blocked by",
	"responsible ai",
	"safety_violation",
	"safety violation",
	"敏感内容",
	"内容审核",
	"内容过滤",
	"内容违规",
	"安全策略",
	"安全过滤",
	"セーフティフィルター",
	"안전 필터",
	"kebijakan konten",
	"política de contenido",
	"contenido bloqueado",
}

local permission: { string } = {
	"forbidden",
	"permission denied",
	"access denied",
	"not allowed to",
	"region not supported",
	"地域受限",
	"不允许访问",
	"无权访问",
	"權限不足",
	"アクセスが許可されていません",
	"권한이 없습니다",
	"akses ditolak",
	"acceso denegado",
}

Tables.RATE_LIMIT = rateLimit
Tables.CONCURRENCY = concurrency
Tables.OVERLOAD = overload
Tables.DAILY_QUOTA = dailyQuota
Tables.CREDITS = credits
Tables.AUTH = auth
Tables.MODEL = model
Tables.ENDPOINT = endpoint
Tables.REQUEST = request
Tables.CONTEXT = context
Tables.UNSUPPORTED = unsupported
Tables.ATTACHMENT = attachment
Tables.FILTER = filter
Tables.PERMISSION = permission

Tables.RATE_LIMIT = rateLimit
Tables.CONCURRENCY = concurrency
Tables.OVERLOAD = overload
Tables.DAILY_QUOTA = dailyQuota
Tables.CREDITS = credits
Tables.AUTH = auth
Tables.MODEL = model
Tables.ENDPOINT = endpoint
Tables.REQUEST = request
Tables.CONTEXT = context
Tables.UNSUPPORTED = unsupported
Tables.ATTACHMENT = attachment
Tables.FILTER = filter
Tables.PERMISSION = permission

return Tables
