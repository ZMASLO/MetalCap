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

## Skąd biorą się dane

Metal HUD z `MTL_HUD_LOG_ENABLED=1` wypisuje raz na sekundę linię `metal-HUD: …` z czasami wszystkich klatek. Trafia ona w dwa miejsca:

- **stderr gry** — pełne dane,
- **log systemowy** — na macOS 27 czasy klatek są zastąpione przez `<private>`.

Stąd dwa tryby pracy:

### Uruchom grę przez MetalCap (działa od razu)

„Uruchom grę…” w oknie lub menu: wybierasz aplikację, MetalCap startuje ją z włączonym HUD i czyta jej stderr. Działa dla gier, które da się uruchomić bezpośrednio z pliku `.app`.

### Metal HUD globalnie (wymaga odblokowania logu)

Przełącznik „Metal HUD” ustawia `MTL_HUD_ENABLED=1` i `MTL_HUD_LOG_ENABLED=1` przez `launchctl setenv` dla wszystkich aplikacji uruchomionych od tej chwili (Steam i CrossOver trzeba zrestartować). MetalCap widzi wtedy grę w logu systemowym, ale czasy klatek są ukryte, dopóki dla podsystemu `com.apple.metal.hud` nie zostaną włączone dane prywatne. MetalCap sam tego nie robi.

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
