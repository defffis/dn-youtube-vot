# Контракт native layout в YouTube 21.40.5

Анализ выполнен по уже предоставленному расшифрованному основному Mach-O,
без запуска iOS и без подключения к устройству.

-[YTMainAppControlsOverlayView layoutSubviews], IMP 0x1017052dc:
- вызывает topControls (0x101705638);
- пропускает isHidden-кнопки (0x1017056d4);
- читает текущие yt_width/yt_height (0x1017056ec, 0x101705708);
- рассчитывает размер topControlsAccessibilityContainerView и размещает controls.

Этот участок не вызывает sizeToFit для элементов списка. В 0.2.0 не было
явного размера DN-кнопки; также alpha задавался только из одного callback.
Это установленные пробелы реализации, но они не заменяют runtime-диагностику
причины невидимости на пользовательском телефоне.

0.2.1 использует UIButton с frame/bounds/intrinsicContentSize 44x44,
обновляет состояние перед/после native layout и зеркалит alpha/hidden
штатной overflowButton. Обработаны setOverlayVisible:,
setTopOverlayVisible:isAutonavCanceledState:, setVideoControlsVisibility:.
При смене скрытого/видимого состояния запрашивается новая компоновка.
Глобальная кнопка поверх приложения не возвращается.

В диагностику добавлены фактический frame, bounds, superview, window,
суммарная alpha/hidden предков, reference, координаты в окне и счётчик layout.
Проверка появления на iPhone остаётся открытой.
