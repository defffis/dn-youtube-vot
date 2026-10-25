# Проверка 0.3.0-alpha

## Реализовано

- NativeUI ведёт в полные настройки; плеер — в quick sound/languages/offset.
- Диагностика в отдельном UITableViewController, копирование/record/stop/export.
- Автор/репозиторий/оригинальное расширение открываются через SFSafariViewController.
- Обновление аккаунта напрямую проверяет профиль и обновляет метаданные без
  перезаписи токена/expiry и остановки звука. Ошибка сети не стирает вход.
- АвтоодинразнаID, текущий/новый ролик, source-language/exclusion/unknown policy.
  Метаданные: selectedAudioFormat.audioTrack, availableCaptionTracks ASR, затем
  protobuf captions и явно выбранный source как fallback. Только безопасные
  проверки методов/KVC с @try; неизвестное не заменяется выдуманным языком.
- Modern/legacy Worker, API/translated-audio modes и sourceMedia proxy.
  OAuth только direct official; для других маршрутов standard voice.
- Ограниченный дисковый кеш, удаление повреждённых/устаревших файлов, reset/clear.
- sameVideo(nil,nil) и idle-stop/disabled-clock исправлены по записи пользователя.

## Проверено

Clang ARM64 iOS16 с -Werror, ld64.lld fatal warnings. Mach-O UUID/constructor/
системные зависимости/ad-hoc page hashes. UBSan host: язык/регионы/track suffix,
excluded/known/unknown 5s, пустые ID, proxy modes, сохранение URL query, защита от
похожего host prefix, прежние 400-step local sync/границы rate/retry и protobuf.
Google Protobuf byte parity для standard/lively запросов не изменилась.

Ручной аудит: параметры proxyMode мигрируют с 0.2; настройки полного/быстрого
экрана разнесены; все новые .mm включены в build. Вход/reset/clear не трогают
логи. Кеш использует SHA256 имени конфигурации, без медиа-URL/OAuth в именах.
Схемы Worker/прокси сверены с upstream vot.js и proxyShared.ts; MIT сохранены.

## Практические ограничения проверки

Реального пользовательского Worker URL нет. Совместимость конечного сервера,
новые UIKit-экраны, refresh/reset/cache и динамическое определение языка на iPhone
не проверены. C++ tests проверяют решения, не исполняют Foundation/AVAudioPlayer.
Подтверждения звука/PiP/фона/экспорта относятся к пользовательской 0.2.3.
Готовая IPA 0.1.0 с отчётом о вылете не считается проверенной.
