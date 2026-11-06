# Okey projesi – oda katılımı düzeltmesi

## Yapılan değişiklikler
- Misafir oturumu artık sessizce başarısız olup uygulamanın devam etmesine izin vermiyor.
- Oda oluşturma ve odaya katılma öncesinde geçerli Supabase oturumu kontrol ediliyor.
- `join_okey_room` RPC hatası artık genel bir mesaj yerine gerçek hata metnini gösteriyor.
- Supabase URL/anon key eksikse açık yapılandırma hatası veriliyor.
- ZIP içindeki `.env` dosyası güvenlik nedeniyle çıkarıldı. `.env.example` eklendi.

## Supabase panelinde yapılması gereken ayar
Supabase Dashboard → Authentication → Sign In / Providers (veya Providers) → Anonymous Sign-Ins seçeneğini etkinleştirin.

Bu proje `signInAnonymously()` kullandığı için bu ayar kapalıysa veritabanı fonksiyonunun beklediği `auth.uid()` oluşmaz ve odaya katılım başarısız olur.

## Yerel ortam değişkenleri
`.env.example` dosyasını `.env` olarak kopyalayın ve kendi Supabase Project URL ile anon/publishable key değerlerinizi girin:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

Service role key kesinlikle frontend'e koyulmamalıdır.

## Önemli
Bu ortamda bağımlılık kurulumu zaman aşımına uğradığı için TypeScript/build doğrulaması tamamlanamadı. Ayrıca Supabase projenize erişimim olmadığı için Anonymous Sign-Ins ayarını veya migration'ların uzaktaki veritabanına uygulanıp uygulanmadığını doğrulayamadım.
