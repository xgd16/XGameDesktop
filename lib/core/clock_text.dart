/// Clock and date strings for the panel header — hand-rolled so the app does
/// not pull in `intl` for two lines of text.
const _weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

/// `09:05` — the hero readout.
String clockHm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// `07` — the seconds trailing the hero readout.
String clockSeconds(DateTime t) => two(t.second);

/// `10月3日 星期六`
String dateCn(DateTime t) => '${t.month}月${t.day}日 ${_weekdays[t.weekday - 1]}';

String two(int value) => value.toString().padLeft(2, '0');
