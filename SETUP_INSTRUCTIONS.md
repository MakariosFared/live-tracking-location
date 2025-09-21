# Live Tracking System - تعليمات الإعداد والاختبار

## نظرة عامة

نظام تتبع مباشر يشبه Uber/inDrive باستخدام Firebase Realtime Database و Maptiler للخرائط.

## المتطلبات المسبقة

- Flutter SDK (الإصدار الحالي)
- Android Studio / VS Code
- حساب Firebase
- حساب Maptiler (اختياري - المفتاح موجود بالفعل)

## خطوات الإعداد

### 1. إعداد Firebase

1. اذهب إلى [Firebase Console](https://console.firebase.google.com/)
2. أنشئ مشروع جديد أو استخدم مشروع موجود
3. أضف تطبيق Android:
   - Package name: `com.example.live_location_tracker`
   - Download `google-services.json`
   - ضع الملف في `android/app/google-services.json`

### 2. إعداد Firebase Realtime Database

1. في Firebase Console، اذهب إلى Realtime Database
2. أنشئ قاعدة بيانات جديدة
3. اختر "Start in test mode" للتطوير
4. قواعد الأمان (للتطوير فقط):

```json
{
  "rules": {
    "rides": {
      "$rideId": {
        "driverLocation": {
          ".read": true,
          ".write": true
        }
      }
    }
  }
}
```

### 3. إعداد Maptiler (اختياري)

- المفتاح موجود بالفعل في الكود: `zytiFRDb2ZK44OCAZuqa`
- يمكنك إنشاء حساب جديد في [Maptiler](https://www.maptiler.com/) واستبدال المفتاح

## إعدادات التطبيق

### تغيير الإعدادات الأساسية

في بداية ملف `lib/main.dart`:

```dart
const String RIDE_ID = "ride123"; // غيّر معرف الرحلة
const String MAPTILER_KEY = "zytiFRDb2ZK44OCAZuqa"; // مفتاح Maptiler
const double UPDATE_INTERVAL_SECONDS = 2.0; // فترة تحديث الموقع
const double DISTANCE_FILTER_METERS = 5.0; // تحديث عند تحرك أكثر من 5 متر
const double ANIMATION_SPEED_MPS = 10.0; // سرعة الحركة الملساء
```

## كيفية الاختبار

### الطريقة الأولى: جهازين حقيقيين

1. **الجهاز الأول (السائق)**:

   - شغّل التطبيق
   - اضغط على زر تبديل الوضع (أعلى يمين الشاشة)
   - تأكد من ظهور "وضع السائق" باللون الأخضر
   - ابدأ المشي أو الحركة

2. **الجهاز الثاني (الراكب)**:
   - شغّل التطبيق
   - تأكد من ظهور "وضع الراكب" باللون الأزرق
   - راقب حركة السيارة على الخريطة
   - راقب تحديث المسافة المتبقية

### الطريقة الثانية: محاكي + جهاز حقيقي

1. **Android Emulator**:

   - افتح Android Studio
   - أنشئ محاكي جديد
   - في Extended Controls → Location
   - اختر "Manual" أو "GPX" لمحاكاة الحركة

2. **الجهاز الحقيقي**:
   - شغّل التطبيق في وضع الراكب
   - راقب حركة المحاكي على الخريطة

### الطريقة الثالثة: محاكيان

1. شغّل محاكيين مختلفين
2. استخدم Extended Controls لتغيير الموقع في كل محاكي
3. راقب التزامن بين المحاكيين

## الميزات المتوفرة

### ✅ الميزات المنجزة

- **وضع السائق**: تتبع GPS وإرسال الموقع إلى Firebase
- **وضع الراكب**: استقبال الموقع وعرضه على الخريطة
- **حركة ملساء**: AnimationController للحركة السلسة
- **خط المسار**: Polyline يظهر مسار السيارة
- **حساب المسافة**: المسافة المتبقية بالمتير
- **خرائط Maptiler**: جودة عالية مع المفتاح المدمج
- **إدارة الصلاحيات**: طلب صلاحيات الموقع تلقائياً
- **واجهة مستخدم**: أزرار تبديل الوضع وتوسيط الخريطة

### 🔧 الميزات الإضافية (اختيارية)

- **تدوير أيقونة السيارة**: حسب اتجاه الحركة
- **تسريع الحركة**: عند المسافات الكبيرة
- **تاريخ المسار**: تخزين مسارات سابقة
- **إشعارات**: تنبيهات عند وصول السائق

## استكشاف الأخطاء

### مشاكل شائعة

1. **لا يظهر الموقع**:

   - تأكد من تفعيل GPS
   - تحقق من صلاحيات الموقع
   - تأكد من وجود `google-services.json`

2. **لا تظهر الخريطة**:

   - تحقق من اتصال الإنترنت
   - تأكد من صحة مفتاح Maptiler

3. **لا تحدث الحركة**:
   - تحقق من اتصال Firebase
   - تأكد من صحة معرف الرحلة (RIDE_ID)

### رسائل الخطأ

- `Permission denied`: تأكد من صلاحيات الموقع
- `Firebase connection failed`: تحقق من `google-services.json`
- `Map tiles failed`: تحقق من مفتاح Maptiler

## الأمان والإنتاج

### ⚠️ تحذيرات مهمة

1. **قواعد Firebase**: غير قواعد الأمان قبل النشر للإنتاج
2. **مفاتيح API**: لا تشارك مفاتيح Maptiler في الكود العام
3. **الصلاحيات**: تأكد من طلب الصلاحيات الضرورية فقط

### قواعد Firebase للإنتاج

```json
{
  "rules": {
    "rides": {
      "$rideId": {
        "driverLocation": {
          ".read": "auth != null",
          ".write": "auth != null && auth.uid == $rideId"
        }
      }
    }
  }
}
```

## الدعم والمساعدة

- تحقق من logs في Android Studio
- استخدم `debugPrint()` لتتبع البيانات
- راجع وثائق Firebase و Maptiler

---

**تم إنشاء هذا المشروع بواسطة AI Assistant**
**تاريخ الإنشاء**: ${DateTime.now().toString().split(' ')[0]}
