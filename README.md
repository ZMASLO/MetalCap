# MetalCap

Companion do benchmarków gier na macOS — odpowiednik CapFrameX. Przechwytuje czasy klatek z Metal Performance HUD i liczy AVG, P1 oraz 1% Low tak samo jak CapFrameX.

## Budowanie

Wystarczą Command Line Tools (Xcode nie jest potrzebny).

```sh
swift test              # testy rdzenia
Scripts/make-app.sh     # buduje build/MetalCap.app
open build/MetalCap.app
```

## Użycie

1. Uruchom MetalCap. W pasku menu pojawi się ikona, a na ekranie okno z przechwyceniami.
2. Uruchom grę z Metal HUD — na jeden z dwóch sposobów opisanych niżej.
3. Naciśnij skrót (domyślnie ⌃⌥R), żeby zacząć pomiar; usłyszysz dźwięk. Naciśnij ponownie, żeby skończyć — drugi dźwięk.
4. Wynik pojawi się na liście: AVG, P1, 1% Low i wykres czasu klatki.

Skrót i sposób liczenia 1% Low zmienisz w ustawieniach (ikona zębatki).

HUD musi być widoczny podczas pomiaru: po ukryciu (⇧F9) macOS przestaje aktualizować czasy klatek.

## Lista wyników

- **Komentarz**: pole pod nagłówkiem wyniku, np. na ustawienia grafiki; widać go też na liście.
- **Nazwa**: ikona ołówka przy nazwie albo „Zmień nazwę…” w menu kontekstowym. Nazwę można zastosować do wszystkich wyników tego samego procesu i przyszłych pomiarów.
- **Sortowanie**: nad listą wybór „Data” lub „Nazwa gry” i przycisk kierunku.

## Metryki systemowe

W trakcie pomiaru MetalCap raz na sekundę zapisuje stan systemu i pokazuje go w sekcji „System” pod wykresem czasu klatki:

- **Obciążenie i pamięć GPU** — ze statystyk sterownika GPU w rejestrze systemowym.
- **Temperatura CPU i GPU** — klucze SMC `Tp…`, `Te…`, `Ts…` (rdzenie CPU) i `Tg…` (GPU), ten sam dobór co w mactop. Wykres pokazuje średnią z czujników, kafelek szczyt najcieplejszego. Nazwy kluczy są nieudokumentowane i wykrywane przy starcie.
- **Moc GPU** — licznik energii „GPU Energy” z IOReport.
- **Moc CPU** — licznik „CPU Energy”; na macOS 27 zwraca on zero, więc moc jest szacowana z histogramów mocy klastrów (grupy PMP), tak jak robi to mactop.
- **Moc całego Maca** — klucz SMC `PSTR` (zapasowo `PDTR`, `PD0R`); z niej liczony jest wskaźnik „FPS na wat”.
- **Klastry CPU, taktowanie i wentylator** — aktywność i taktowanie każdego klastra rdzeni oraz taktowanie GPU z IOReport (stany wydajności i tabele częstotliwości menedżera zasilania), obroty wentylatora z kluczy SMC `F<n>Ac`. Klaster wyłączony albo bezczynny nie liczy się jako aktywny.
- **CPU i RAM gry** — czas procesora i zajętość pamięci procesu, z którego pochodzą klatki.
- **Stan termiczny**, zasilanie z baterii i tryb niskiego zużycia energii — jako uwagi w nagłówku wyniku.

Nic z tego nie wymaga uprawnień administratora. Wyniki zapisane wcześniej nie mają tej sekcji.

Odczyty były porównane z mactop 2.1.6 na MacBooku Pro M5 Pro (macOS 27.0.1), w spoczynku i przy obciążeniu CPU: temperatury zgodne do 0,8°C, moc CPU do 2%, moc całego Maca poniżej 1%. `MetalCap --sample 10` wypisuje odczyty co sekundę, żeby takie porównanie dało się powtórzyć.

## Sprzęt i eksport

Każdy nowy wynik zapisuje komputer, na którym powstał: model, identyfikator modelu, układ, liczbę rdzeni CPU (z podziałem na klastry) i GPU, ilość RAM oraz wersję macOS. Linia ze sprzętem jest widoczna pod nagłówkiem wyniku.

Przycisk „Eksportuj” przy wyniku zapisuje:

- **Pełny wynik (JSON)** — metadane, sprzęt, metryki FPS, wszystkie klatki i serię metryk systemowych; pole `formatVersion` oznacza wersję układu pliku.
- **Klatki (CSV)** — wiersz na klatkę: numer, czas od startu, czas klatki, czas GPU, FPS.
- **Metryki systemowe (CSV)** — wiersz na sekundę pomiaru.
- **Podsumowanie wszystkich wyników (CSV)** — wiersz na wynik: metryki FPS, sprzęt, średnie i maksima systemowe.

Format CSV wybiera się w ustawieniach: standardowy (przecinek, kropka dziesiętna) albo dla polskiego Excela (średnik, przecinek dziesiętny).

## Nakładka HUD

Ustawienia → „Nakładka HUD”: wybór wyświetlanych elementów, pozycja, skala i krycie. Odpowiadają zmiennym `MTL_HUD_ELEMENTS`, `MTL_HUD_ALIGNMENT`, `MTL_HUD_SCALE` i `MTL_HUD_OPACITY` i działają dla gier uruchomionych po zmianie.

## Skąd biorą się dane

Metal HUD z `MTL_HUD_LOG_ENABLED=1` wypisuje raz na sekundę linię `metal-HUD: …` z czasami wszystkich klatek. Trafia ona w dwa miejsca:

- **stderr gry** — pełne dane,
- **log systemowy** — na macOS 27 czasy klatek są zastąpione przez `<private>`.

Stąd dwa tryby pracy:

### Uruchom grę przez MetalCap (działa od razu)

„Uruchom grę…” w oknie lub menu: wybierasz aplikację, MetalCap startuje ją z włączonym HUD i czyta jej stderr. Działa dla gier, które da się uruchomić bezpośrednio z pliku `.app`.

### Metal HUD globalnie (wymaga odblokowania logu)

Przełącznik „Metal HUD” ustawia `MTL_HUD_ENABLED=1` i `MTL_HUD_LOG_ENABLED=1` przez `launchctl setenv` dla wszystkich aplikacji uruchomionych od tej chwili (Steam i CrossOver trzeba zrestartować). MetalCap widzi wtedy grę w logu systemowym, ale czasy klatek są ukryte, dopóki log nie zostanie odblokowany.

Przy starcie MetalCap sprawdza, czy log jest odblokowany, i jeśli nie — pokazuje instrukcję. Odblokowanie to profil konfiguracyjny z ładunkiem `com.apple.system.logging`, który włącza `Enable-Private-Data` wyłącznie dla podsystemu `com.apple.metal.hud`:

1. „Zainstaluj profil…” (w monicie albo w ustawieniach) zapisuje `MetalCap-FrameTimes.mobileconfig` w Pobranych, przekazuje go systemowi i otwiera Ustawienia systemowe.
2. W Ustawieniach systemowych: Ogólne → Zarządzanie urządzeniem → dwuklik na „MetalCap – czasy klatek” → Zainstaluj. Profil jest niepodpisany, macOS zapyta o hasło.
3. Uruchom ponownie grę; zmiana może zacząć działać po minucie lub dwóch.

Profil usuwa się w tym samym miejscu Ustawień systemowych. Bezpośredni zapis pliku w `/Library/Preferences/Logging/Subsystems/` nie wchodzi w grę: macOS 27 odrzuca go nawet z uprawnieniami administratora.

## Język

Interfejs jest po polsku i po angielsku. Domyślnie język jest wybierany automatycznie: polski na systemie ustawionym na polski, angielski na każdym innym. W ustawieniach można wymusić jeden z nich; menu systemowe przełączą się po ponownym uruchomieniu aplikacji.

## Metryki

Liczone jak w `FrametimeStatisticProvider.cs` z CapFrameX:

- **AVG** — liczba klatek × 1000 / suma czasów klatek.
- **P1, P0.2, P5, mediana…** — kwantyl R-8 (jak `MathNet.Numerics`) z wartości FPS.
- **1% Low (Average)** — 1000 / średnia czasów klatek nie krótszych niż kwantyl 0.99.
- **1% Low (Integral)** — najwolniejsze klatki sumowane do 1% czasu pomiaru; wynik to FPS klatki, na której próg został osiągnięty (definicja MSI Afterburner).

## Tryb bez okna

```sh
build/MetalCap.app/Contents/MacOS/MetalCap --run /ścieżka/do/Gry.app --seconds 30
```

Uruchamia grę, mierzy przez podany czas i wypisuje metryki.

Przechwycenia leżą w `~/Library/Application Support/MetalCap/Captures/` jako pliki JSON.
