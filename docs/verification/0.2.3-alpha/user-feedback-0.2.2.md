# Отчёт пользователя 0.2.2

YouTube 21.40.5, iOS 27.0.1, video 0flkwrqq28s.
Пользователь: оригинал стал тише; активный значок жёлтый, при воспроизведении
мигает жёлтым/зелёным, озвучки не слышно. Запрошены запись/остановка/экспорт лога.

Снимок: enabled YES, content 324.657, audio 324.573, AVPlayer state 2/rate 1,
ready 1, gate playing, clock moving YES, paused/seeking NO. Duration 1441.272,
translation volume 1, muted NO. Original 0.191, saved 1, ducking YES, setter YES.
Play commands 151, timer passes 66. Ad/survey/intro/MDX/external 0.
Network session/create 200, translate 200, VOT status 1, lively requested YES.

В предыдущем коде tick повторно вызывается из completion удалённого seek, а
периодический tick ставит AVPlayer на паузу во время seek. При запаздывающих seek
возможно повторное отставание от видео. Счётчики и мигание совместимы с churn,
но без непрерывного лога эта гипотеза не доказана. AVPlayer playing в одном снимке
не доказывает наличие декодированных сэмплов или слышимость.

Приглушение оригинала на устройстве подтверждено пользователем. Слышимый перевод
не подтверждён. Исходный файл/его содержимое на устройстве не исследованы.
