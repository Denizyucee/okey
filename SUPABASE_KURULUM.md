# Supabase kurulumu

1. Supabase Dashboard'da doğru `okey` projesini aç.
2. Sol menüden **SQL Editor** > **New query** seç.
3. `supabase/OKY_SUPABASE_KURULUM.sql` dosyasının tamamını açıp SQL Editor'e yapıştır.
4. **Run** düğmesine bir kez bas ve işlemin başarıyla bittiğini kontrol et.
5. Authentication > Sign In / Providers bölümünde **Allow anonymous sign-ins** açık kalsın.
6. Vercel'de `VITE_SUPABASE_URL` ve `VITE_SUPABASE_ANON_KEY` değişkenleri tanımlı olmalı. Publishable key kullanılabilir; `service_role` / secret key'i frontend'e koyma.

Bu kurulum, `okey_rooms`, `okey_players`, `okey_games` ve `okey_private_hands` tablolarını ve uygulamanın çağırdığı RPC fonksiyonlarını oluşturur. Özel taş elleri `okey_private_hands` tablosunda tutulur; tarayıcı rolleri bu tabloyu doğrudan okuyamaz.

**Önemli:** Bu tek kurulum dosyasını çalıştır. Eski `supabase/migrations` dosyalarını ayrıca sırayla çalıştırma; bunlar eksik/uyumsuz ara migration'lardır. Kurulum mevcut oyun tablolarını silmez; eksik sütunları ekler. Var olan veriler korunur.
