# Изменение воспроизведения 0.2.2

- PlaybackClock использует измеренное продвижение contentVideoMediaTime,
  а не приватный attemptingToPlay. Последний остаётся только в диагностике.
- Пауза останавливает озвучку сразу. Устаревший pause-callback восстанавливается
  только при свежем продвижении часов; seeks/invalid clocks не считаются playback.
- Явный playImmediatelyAtRate, automaticallyWaitsToMinimizeStalling=NO для
  синхронизируемого AVPlayer. После seek выполняется немедленная повторная оценка.
- Зелёный: playing, ненулевая rate/громкость и не muted. Жёлтый: готовая дорожка
  включена, но не воспроизводится. Ожидание URL/ready продолжает показывать таймер.
- Приглушение оригинала применяется при playing; пауза/seek/ошибка его снимают.
- Gate, clock moving, diagnostic intent, commands, duration и уровни добавлены в лог.

Первичные источники AVFoundation:
https://developer.apple.com/documentation/avfoundation/avplayer/playimmediately(atrate:)
https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling

Host-тесты: продвижение/остановка, свежесть samples, stale pause recovery,
реальные pause/resume, forward/backward seeks, NAN, 0.25x, reported clock values,
coverage и UI ready-but-paused vs playing. Сборка/подписи проверены.
Успешное воспроизведение на физическом iPhone ещё не подтверждено.
