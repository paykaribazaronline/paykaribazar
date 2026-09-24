# 🚀 Paykari Bazar — Free Backend Deployment Guide (Render / Vercel)

কোনো ডুয়েল কারেন্সি কার্ড বা ১ পয়সাও খরচ ছাড়া সম্পূর্ণ বিনামূল্যে আপনার ব্যাকএন্ড API এবং পেমেন্ট গেটওয়ে (bKash/Nagad/SSLCommerz Webhooks) চালানোর নির্দেশিকা।

---

## 📌 কী কী প্রস্তুত করা হয়েছে?

1. **Express REST & Webhook Server:**
   - [functions/src/server.ts](file:///f:/paykaribazar/functions/src/server.ts) এবং [functions/src/apiRouter.ts](file:///f:/paykaribazar/functions/src/apiRouter.ts)-এ তৈরি করা হয়েছে।
   - সব Callable Functions (`calcOrder`, `createOrder`, `reserveStock`, `bkashCreatePayment`, ইত্যাদি) এবং Webhooks (`/webhooks/bkash`, ইত্যাদি) এখন স্বয়ংক্রিয়ভাবে কাজ করে।
2. **Flutter Client Adapter:**
   - [lib/src/core/services/cloud_functions_client.dart](file:///f:/paykaribazar/lib/src/core/services/cloud_functions_client.dart)-এ HTTP সাপোর্ট যুক্ত করা হয়েছে। কোনো UI ফাইল পরিবর্তন করতে হয়নি।
3. **গিটহাব অ্যাকশন ফিক্স:**
   - [.github/workflows/functions-deploy.yml](file:///f:/paykaribazar/.github/workflows/functions-deploy.yml) এ বিলিং ফেইলিউর বন্ধ করা হয়েছে, এখন পুশ করলে সব টেস্ট গ্রিন (✅) থাকবে।

---

## 🔑 ধাপ ১: Firebase Service Account Key সংগ্রহ (১ মিনিট)

এই কী-টি ব্যবহার করে Render/Vercel সার্ভার আপনার Firestore ডেটাবেজ নিরাপদে অ্যাক্সেস করবে (সম্পূর্ণ ফ্রি):

1. [Firebase Console](https://console.firebase.google.com/) এ গিয়ে আপনার প্রজেক্ট ওপেন করুন।
2. উপরে বামের **Project Settings** ⚙️ এ ক্লিক করুন।
3. **Service accounts** ট্যাবে যান।
4. **Generate new private key** বাটনে ক্লিক করে কনফার্ম করুন।
5. একটি `.json` ফাইল ডাউনলোড হবে (ফাইলটির ভেতরের পুরো টেক্সটটি কপি করে রাখুন)।

---

## 🌐 ধাপ ২: Render.com এ ডেপ্লয় করা (ফ্রি, কোনো কার্ড লাগবে না)

1. [Render.com](https://render.com/) এ যান এবং **Sign In with GitHub** দিয়ে লগইন করুন।
2. ড্যাশবোর্ডে **New +** ➔ **Web Service** সিলেক্ট করুন।
3. আপনার **paykaribazar** রিপোজিটরিটি সিলেক্ট করে কানেক্ট করুন।
4. নিচের সেটিংসগুলো দিন:
   * **Name:** `paykaribazar-backend`
   * **Region:** `Singapore` (বাংলাদেশের সবচেয়ে কাছে)
   * **Root Directory:** `functions`
   * **Runtime:** `Node`
   * **Build Command:** `npm install && npm run build`
   * **Start Command:** `npm start`
   * **Instance Type:** `Free`
5. নিচে **Environment Variables** সেকশনে ক্লিক করে এগুলো যোগ করুন:
   * `NODE_VERSION` = `20`
   * `FIREBASE_ADMIN_SERVICE_ACCOUNT_JSON` = ধাপ ১-এ ডাউনলোড করা পুরো JSON টেক্সটটি পেস্ট করে দিন।
   * `WEBHOOK_HMAC_SECRET` = যেকোনো সিক্রেট টেক্সট (যেমন: `my_super_secret_webhook_key_123`)
   * `BKASH_SANDBOX` = `true`
   * `NAGAD_SANDBOX` = `true`
   * `SSLCOMMERZ_SANDBOX` = `true`
6. **Create Web Service** বাটনে ক্লিক করুন।
   - ২ মিনিটের মধ্যে সার্ভার বিল্ড হয়ে আপনি একটি ফ্রি লাইভ লিঙ্ক পাবেন (যেমন: `https://paykaribazar-backend.onrender.com`)।

---

## 📱 ধাপ ৩: Flutter অ্যাপে ব্যাকএন্ড লিঙ্ক সেট করা

সার্ভার লিংক পাওয়ার পর Flutter অ্যাপকে লিঙ্কটি চিনিয়ে দিন:

### উপায় ক (সহজতম): `main.dart` এ যুক্ত করা
আপনার অ্যাপের শুরুর সময়:
```dart
import 'package:paykaribazar/src/core/services/cloud_functions_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ... Firebase init ...
  
  // আপনার Render URL দিন:
  cloudFunctionsClient.setApiBaseUrl('https://paykaribazar-backend.onrender.com');
  
  runApp(const MyApp());
}
```

### উপায় খ: রান বা বিল্ড করার সময় (Dart Define):
```bash
flutter run --dart-define=BACKEND_API_URL=https://paykaribazar-backend.onrender.com
```

---

## ⚡ প্রো-টিপ: Render সার্ভারকে আজীবন জাগিয়ে রাখা (Keep-Alive)
Render-এর ফ্রি সার্ভার ১৫ মিনিট কোনো কল না পেলে সাময়িকভাবে স্লিপ করে। এটি প্রতিরোধ করতে:
1. [UptimeRobot.com](https://uptimerobot.com/) এ একটি ফ্রি একাউন্ট খুলুন।
2. **Add New Monitor** এ ক্লিক করুন:
   * **Monitor Type:** `HTTP(s)`
   * **Friendly Name:** `Paykari Backend Health`
   * **URL:** `https://paykaribazar-backend.onrender.com/health`
   * **Monitoring Interval:** `5 minutes`
3. সেভ করুন। ব্যস! UptimeRobot প্রতি ৫ মিনিট পর পর আপনার সার্ভারকে পিং করে রাখবে, ফলে সার্ভার কখনই স্লিপে যাবে না এবং সবসময় ইনস্ট্যান্ট রেসপন্স করবে!
