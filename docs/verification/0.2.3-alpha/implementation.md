# Проверка 0.2.3-alpha

Изменён backend: HTTPS download полного файла (128 МБ / 240 с), временный файл,
AVAudioPlayer prepare/play/rate/currentTime, synchronous local seeks. Остальной
протокол VOT и авторизация не менялись. Никаких category/setActive изменений
глобальной аудиосессии YouTube. API звукозаписи не используются.

Удалены повторный вход tick из seek completion и потоковый AVPlayer озвучки.
LocalTransport не запрашивает play для играющей дорожки и ограничивает retry1Гц.
400 шагов host-модели непрерывного playback: один start, два seek (начальное
выравнивание и одна пользовательская перемотка), без циклических перезапусков.
Также pause, ad, конец покрытия, границы 0.5/2x и неподдерживаемые скорости.
Это модель принятия решений, не реальный iOS-декодер.

FlightRecorder: serial background writer, JSONL, nonfinite числа превращаются
в null, file errors/state, лимиты 15 мин / 12 МБ. UIKit-снимок собирается на main,
запись/flush/copy на отдельной очереди. Экспорт через UIActivityViewController,
согласованный снимок возможен при продолжающейся записи. Ручной аудит полей:
OAuth/headers/raw payload/подписанные URL/имена аккаунта/портов отсутствуют.
Значения сетевых summary формируются из внутренних method/path/status/size.

## Выполнено

- Clang -Wall -Wextra -Werror, ARM64 iOS 16+, ld64.lld fatal warnings.
- Секции/UUID/constructor/системные зависимости/ad-hoc page hashes Mach-O.
- UBSan C++ policy/protobuf, Google Protobuf byte parity.
- Ручной просмотр cancellation/generation/cleanup, bounds и полей recorder.

## Не выполнено

Нет доступного iPhone/iOS simulator runtime: AVAudioPlayer/decode/metering,
фактический звук/синхронизация, влияние других модов, recording/export/share UI,
сохранение после OS suspension не проверены. Экспериментальный alpha.

## Первичные справочники API

- https://developer.apple.com/documentation/avfaudio/avaudioplayer
- https://developer.apple.com/documentation/avfaudio/avaudioplayer/currenttime
- https://developer.apple.com/documentation/avfaudio/avaudioplayer/enablerate
- https://developer.apple.com/documentation/avfaudio/avaudioplayer/rate
- https://developer.apple.com/documentation/avfaudio/avaudioplayer/ismeteringenabled
