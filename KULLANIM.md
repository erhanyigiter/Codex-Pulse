# Codex Pulse 1.3

Hesap başlığının solundaki tutamacı başka bir hesabın üzerine sürükleyerek sırasını değiştirin. Sıralama bu Mac’te kaydedilir.

`~/.codex` altındaki varsayılan oturum da listelenir. Haftalık kullanım %100 olduğunda sayaçlar haftalık yenilenmeyi gösterir. Kullanım %0–49 yeşil, %50–99 sarı, %100 ve üzerinde kırmızıdır.

Mac menü çubuğunda Monocode Codex hesaplarını ayrı ayrı gösteren yerel uygulama.
Uygulama e-ticaret projesinden bağımsızdır; kurulu `.app` paketi kendi kodunu içerir.
Kaynak klasörünü taşımanız veya silmeniz kurulu uygulamayı etkilemez.

## Dil ve hesap listesi

Varsayılan dil **İngilizce**dir. **Settings → Language → Türkçe → Save settings**
yoluyla Türkçe’ye geçebilirsiniz; yeniden açmanız gerekmez. Menüler, durum mesajları,
bildirimler, geçmiş ve tarih gösterimleri seçilen dili kullanır; takma adlar çevrilmez.

Dropdownlar başlangıçta kapalıdır ve aynı anda birden fazla hesap açık kalabilir.
Kapalı satırda kalan süre küçük bir göstergeyle görünür; pencereyi büyütmez.
Pencere bir ile üç hesabın boyuna uyar; fazlası kaydırılır. Takma ad alanında **Enter**
ile kaydedebilirsiniz; kayıt onaylandığında hesap ayarları penceresi kapanır.

Limit çubukları **5 saatlik limit** ve **Haftalık limit** olarak adlandırılmıştır.
Bu etiketleri uygulama belirler; Monocode’dan hazır metin olarak gelmez.
Switch’i kapalı hesap açılışta, yenilemede, hata tekrarında, uyanmada ve CLI durum
kontrolünde de sorgulanmaz. Eski hata kayıtları geçmişte kalır; yeni kontrol yapılmaz.

## Başlatma ve durdurma

1. `Codex Pulse.app` uygulamasını açın. Menü çubuğundaki dalga simgesine tıklayın.
2. İlk açılışta hesapların limitleri bir kez okunur. Varsayılan olarak izleme kapalıdır.
3. **Başlat** açık anahtarlı tüm hesapların izlenmesini etkinleştirir.
4. **Durdur** yeni sorguları engeller ve çalışan Codex alt işlemini sonlandırır.
5. Tamamen kapatmak için simgeye sağ tıklayıp **Çıkış** seçin; paneldeki `…` menüsünde de vardır.
6. Kartın sağındaki anahtar yalnızca o hesabı kapatır/açar. Yanındaki ayar simgesi,
   takma ad ve hesaba özel kontrol ayarlarını açar.

## Süreler ve kontrol modu

**Ayarlar → Sadece süre dolunca** yeni varsayılandır. Sunucunun bildirdiği yenilenme
zamanı öğrenildikten sonra ara durum isteği yapılmaz. Sayaç yerel hesaplanır; ekranda
saniyelerin ilerlemesi ağ isteği oluşturmaz. Yenilenme saatinden 15 saniye sonra
limitin gerçekten açıldığı ve sunucunun kullanım izni verdiği doğrulanır.

**Ara kontrol de yap** seçerseniz kaç dakikada bir durum okunacağını kendiniz
belirlersiniz. Örneğin 12, 47 veya 180 dakika yazabilirsiniz; hazır 20/30 seçenekleri yoktur.
Yenilenme saati daha erkense yine o anda kontrol yapılır.

**Hata / gecikme sonrası kontrol** ayrı bir dakika değeridir (varsayılan 5).
İnternet kesilirse, oturum okunamazsa veya sunucu yenilenmeyi henüz göstermiyorsa
bu aralıkta yalnızca durum tekrar okunur. Dakika alanları 1–10080 arasında tam sayı kabul eder.
Haftalık limit doluysa, bilinen haftalık yenilenme zamanına kadar beklenir.
Bir sorgu gönderildikten sonra yeni pencerenin saati bilinmiyorsa bu aralıkla tekrar öğrenilir.

**Model sorgusu aynı yenilenme için yalnızca bir kez denenir.** Hata, durdurma veya
yeniden açılış bu denemeyi otomatik tekrarlamaz. Geçmişi temizlemek de bu kaydı silmez.
Uygulama kota artırmaz, limitleri sıfırlamaz ve reset kredisi kullanmaz. Kısa `OK`
sorgusu mevcut hesabın kullanımından tüketir; yeni pencereyi başlatması garanti değildir.

Birden fazla hesap sırayla işlenir. Aynı gerçek hesap iki Monocode profiline ekliyse
aynı pencere için ikinci sorgu gönderilmez. API anahtarıyla çalışan veya beş saatlik
penceresi bulunmayan hesaplara otomatik model sorgusu gönderilmez.

## Hesap ayarları ve menü çubuğu

Her hesabın kartındaki ayar simgesinden takma ad verebilirsiniz; örneğin “İş hesabı”.
“Bu hesap için farklı kontrol ayarları” seçeneği ile mod, ara kontrol süresi ve
hata sonrası kontrol süresi yalnızca o hesap için değişir. Kapalıysa genel ayarlar kullanılır.

**Ayarlar → Menü çubuğu** bölümünde tek hesap seçebilir veya en yakın yenilenme
zamanının gösterilmesini isteyebilirsiniz. Duraklatıldığında seçili hesabın sayacı
`Ⅱ` işaretiyle görünür. “En yakın yenilenme” seçiliyse duraklatılmış bilgisi gösterilir.

## Sessiz saatler, bildirimler ve açılış

Sessiz saatleri **HH:MM** biçiminde, Mac’in yerel saatine göre girin. Gece yarısını
aşabilir; örneğin 23:00–08:00. Bu saatlerde yeni otomatik model sorgusu ve bildirim
oluşturulmaz. Geciken işlem sessiz saatler bitince tekrar doğrulanır; kaçırılan
pencereler için toplu sorgu gönderilmez. Başlamış bir sorgu sessiz saate girince
geriden iptal edilmez; yeni sorgu başlatma engellenir.

Bildirimler varsayılan kapalıdır. **İşlem ve hata bildirimleri** seçeneğini kaydedince
macOS izin ister. Başarılı sorgu, başarısız sorgu ve yeni oturum/bağlantı hatasında
bildirim gösterilir. Aynı bağlantı hatası her kontrolde yeniden bildirilmez.
İzin vermediyseniz Sistem Ayarları → Bildirimler → Codex Pulse bölümünden açabilirsiniz.
macOS Odak veya Rahatsız Etme modu bildirimlerin görünmesini ayrıca etkileyebilir.

**Uygulama açılınca izlemeyi başlat** tercihi bir sonraki uygulama açılışını etkiler;
şu anda çalışan izlemeyi değiştirmez. Varsayılan kapalıdır.
**Mac oturumu açılınca uygulamayı aç** ise macOS Giriş Öğeleri kaydını yönetir.
Gerekirse Sistem Ayarları → Genel → Giriş Öğeleri bölümünde onaylayın.

Mac kapalıyken veya uyurken işlem yapılamaz. Uyandığında izleme açıksa mevcut durum
okunur ve gerekli tek sorgu doğrulama sonrasında gönderilebilir.
Başlıktaki yenile düğmesi yalnızca durum okur; model sorgusu başlatmaz.

## İşlem geçmişi ve yerel veriler

**Geçmiş** sekmesi son 300 işlemi gösterir: durum kontrolleri, sorgular, hatalar,
ayar değişiklikleri ve durdurmalar. Başarılı sorgu veya hata filtresi kullanılabilir.
Dışa aktar simgesiyle JSON dosyası kaydedebilirsiniz. Çöp kutusu yalnızca görünür
geçmişi temizler; yinelenen sorguyu engelleyen ayrı işlem kayıtlarını korur.

Ayarlar, takma adlar, kayıtlar ve işlem geçmişi yalnızca şu konumda tutulur:

`~/Library/Application Support/Codex Pulse/state.json`

Dosya kullanıcıya özel izinlerle yazılır. Hesap e-postaları panelde görüntülenir;
yerel geçmiş hesap klasörü kimliklerini, tercihler takma adları ve işlem saatlerini tutar.
Uygulama parola veya erişim token’ı saklamaz, okumaz veya kopyalamaz. Codex CLI
kendi mevcut oturumlarını kullanır ve gerekirse kendi kimlik doğrulamasını yeniler.
Monocode’un seçili hesabını değiştirmez.

## Arkadaşına gönderme

Paylaşım dosyası: **Codex-Pulse-1.3.1-universal.dmg**.
İçindeki `Codex Pulse.app` uygulamasını `Applications` klasörüne sürükleyin.
Yönetici yetkisi olmadan kişisel `~/Applications` klasörüne de kopyalanabilir.
DMG açıkken çalıştırmak yerine önce uygulamayı kopyalayın.

Universal 2 paketi Apple Silicon ve Intel için derlenir; bu oturumdaki gerçek çalıştırma
testleri Apple Silicon Mac üzerinde yapılmıştır. macOS 13+ gerekir. Ayrıca:

- `/usr/bin/python3` bulunmalı. Bu Mac’te kurulu; başka Mac’te Apple komut satırı
  araçları/Python 3 kurulumu gerekebilir.
- Codex CLI `PATH`, `~/.local/bin`, `/opt/homebrew/bin` veya `/usr/local/bin` içinde bulunmalı.
- Monocode’da kişinin **kendi** ChatGPT/Codex hesabına giriş yapılmış olmalı.

Uygulama hesapları bu kullanıcıya ait aşağıdaki klasörlerden keşfeder:

`~/Library/Application Support/com.monocode.desktop/provider-accounts/codex/account-*`

Her hesap ayrı `CODEX_HOME` ile çalışır. Monocode klasör düzeni değişirse keşif kodunu
güncellemek gerekebilir. Yeni hesaplar izleme açıkken yerel olarak keşfedilir;
yenile düğmesiyle de taranabilir.

DMG ve kaynak ZIP kullanıcı hesabı, ayarlar, geçmiş veya kimlik doğrulama dosyası içermez.
Uygulama yerel/ad-hoc imzalıdır; Apple Developer ID veya noter onayı yoktur.
DMG yapmak bunu değiştirmez; başka Mac’te macOS açılışı engelleyebilir.
Dağıtım için noter onayı ayrıca Apple geliştirici hesabı ve imzalama gerektirir.

**Codex-Pulse-1.3.1-source.zip** kaynak kodunun bağımsız kopyasıdır. İstediğiniz klasöre
çıkarıp geliştirebilirsiniz; e-ticaret projesinin Node/Prisma dosyalarına ihtiyaç duymaz.

## Geliştirme ve doğrulama

Kaynak klasörü içinden:

```sh
bash build.sh
python3 -m unittest discover -s tests -v
python3 backend.py --check
bash package.sh --no-build
```

`backend.py --check` yalnızca hesapların limitlerini okur; model sorgusu göndermez.
`build.sh` Swift araçları gerektirir ve Universal 2 `.app` üretir. `package.sh` DMG ile
kaynak ZIP üretir; `hdiutil` için macOS disk görüntüsü servislerine erişim gerekebilir.

Eski terminal betiği çalışıyorsa uygulamayı kullanmadan önce o terminalde **Ctrl+C**
ile kapatın. Eski betik ile bu uygulamanın işlem kayıtları ayrıdır; birlikte çalıştırmayın.
Bu uygulama OpenAI veya Monocode’un resmî ürünü değildir.

Kaynak: [Codex App Server](https://developers.openai.com/codex/app-server/).
