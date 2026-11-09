# NILIT Yarn Break Control (בקרת הפסקות חוטים)

פרויקט ניטור ובקרת הפסקות חוטים עבור קווי ייצור נילית (Barmag Serial DW / Vuniq COM).

## מבנה התיקייה

- `counter-src-1.0.8/` — קוד מקור מלא ועדכני של רכיב ה-Counter (VB6) בגרסה `1.0.8-ef`.
- `packages/` — חבילת עדכון מוכנה להתקנה בשטח (`NILIT_EF_UPDATE_1.0.8` וקובץ `NILIT_EF_UPDATE_1.0.8.zip`).
- `deployment-scripts/` — סקריפטי פריסה, הפעלה, בדיקה ו-Watchdog מלאים.
- `HANDOFF.md` — מסמך ההעברה הראשי, ארכיטקטורת המערכת, פרוטוקולים והסברים טכניים מעמיקים.
- `Line-GH-analysis.he.md` — ניתוח שדה לקווי G/H.
- `Field-checklist.he.md` — צ'קליסט בדיקות והתקנה בשטח.
- `Field-photos-2026-09-27.he.md` — תיעוד תמונות מהמפעל וניתוח ממצאים.
- `Field-hex-2026-09-27.he.md` — ניתוח הקס של תעבורת תקשורת טורית.
- `GH-startup-investigation.he.md` — חקירת אתחול ואנומליות תהליכים.
- `GH-watchdog-current-scope.he.md` — ארכיטקטורת מערכת ה-Watchdog.
- `comparison-mn-gh/` — השוואות וניתוחים בין קווי ייצור.

## עדכון גרסה 1.0.8 (תיקון השבתה / אחזקה)
גרסה `1.0.8-ef` פותרת את קריסת הקריאה (שגיאה `0x800408FD - Empty or oversized numeric value`) כאשר מכונות או ראשים נמצאים בהשבתה/אחזקה:
1. `VuniqLink.bas` — הוספת פונקציית `ReadOptionalNumber` המאפשרת החזרת ערך ברירת מחדל (0) במקרה ש-Vuniq/הבקר מחזירים מחרוזת ריקה (`""`) עבור `WipingDate`, `WipingTime`, `Maintenance` ו-`WindingRaw`.
2. סריקת ה-Port אינה נתקעת בראש 1 וממשיכה לרוץ באופן רציף גם בהשבתה מלאה של הקווים.
