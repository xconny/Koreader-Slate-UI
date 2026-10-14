# SLATE UI KOREADER PLUGIN

**An interactive home gui for KOReader—books, quotes, weather, reading statistics, quick launch apps and games, together\.**

## 🏠 Your reading home

- **Current book at a glance:** cover, title, author, progress bar and percentage read\.
- **Choose your backdrop:** current\-book cover or your own background image, with image\-scaling options\.
- **Everyday essentials:** city, time, battery, weather and moon phase on the main widget\.
- **One\-touch access:** library, recents, quotes, reading statistics, apps and games\.

## 📚 Visual library & recent reads

- **Browse by cover:** your entire library, folder\-based Categories and reading history\.
- **Stay in your library:** open category folders within the same window and return with the back arrow\.
- **Tap to read:** open books directly from covers in library, recents and quote popups\.
- **Long\-press a book:** open that book’s description and saved highlights from the current\-book widget, Library or Recents\. The library stays open behind it\.
- **Preview the artwork:** long\-press covers in book and quote popups to enlarge them\.
- **Build your own grids:** configure books per row, rows per page and folders per Categories page\.
- **See your progress:** optional progress bars and percentages on book thumbnails\.
- **Bypass Slate’s browser:** configure the Library button to open KOReader’s library directory directly, and the Recents button to open KOReader’s native reading history\. Each button has its own setting\.

## 💬 Highlights & quotes

- **Rediscover your reading:** current\-book highlights, random quotes and quotes from one or more selected books\.
- **Keep your collection current:** manual or automatic extraction of saved KOReader highlights\.
- **Search all quotes:** find passages by quote text, book title or author\.
- **Read with context:** book cover, title, author, book\-page reference and quote/page counters\.
- **Return to the passage:** jump directly from a quote to its location in the book\.
- **Read comfortably:** adjustable fonts, paginated text and swipe navigation; page turners appear when needed\.

### ⭐ Favourites & tags

- **Save a favourite:** toggle the star beside a highlight or quote\.
- **Browse your favourites:** open the favourites view from the Quotes menu, with book context and direct passage navigation\.
- **Organise by theme:** assign multiple tags to a quote, or create a tag while reading\.
- **Edit with checkboxes:** select and apply existing tags through a consistent tag picker\.
- **Explore TAG&#40;S&#41;:** a dedicated tab inside Quotes for all tagged quotes or a selected set of tags\.
- **Manage your collection:** add and remove tag names, or remove a tag from an individual quote—all through the quote controls and menus\.

## 📝 Book descriptions & metadata

- **Embedded descriptions first:** use meaningful description text already stored in the book\.
- **Online fallbacks:** Open Library, optional Google Books and Wikipedia\.
- **Read offline:** downloaded descriptions are cached locally\.
- **Fetch in the background:** queue missing descriptions, retry remaining books and resume paused downloads after waking\.
- **Refine a search:** browse missing books by thumbnail and enter a custom search title\.
- **Correct metadata:** edit book titles and authors through a visual picker or the book\-description menu\.
- **Inspect failed lookups:** short on\-screen status, a detailed search\-query viewer and optional diagnostic logging\.

## 🌦️ Weather & moon phases

- **Current conditions:** local weather and temperature on your home screen\.
- **Seven\-day forecast:** weather icons, condition summaries, high/low temperatures and rain probability\.
- **Dated moon phases:** view the phase alongside each forecast day\.
- **Your location, your units:** configurable location and Celsius/Fahrenheit display\.
- **Cached weather:** configurable cache duration and saved data when connectivity is unavailable\.
- **No weather API key required:** powered by Open\-Meteo\.

## 📊 Reading statistics

- **See your habits:** reading\-time charts and pages\-read totals from KOReader’s statistics database\.
- **Choose a range:** last seven days, last twelve months, custom dates or your entire reading history\.
- **Explore the detail:** daily or monthly reading breakdowns alongside the chart\.
- **Background loading:** refresh reading statistics while keeping Slate responsive\.

## 🚀 Quick\-launch apps & games

- **Choose your shortcuts:** select which installed KOReader plugins appear\.
- **Two dedicated tabs:** swipe left or right between Apps and Games\.
- **Adaptive layouts:** two columns for smaller collections; three when a tab contains more than twelve selected plugins\.
- **Consistent labels:** shared text sizing across launcher entries\.
- **Settings without leaving Slate:** menu\-only plugins without their own GUI open a dedicated Slate\-style popup, giving you direct access to their available settings and actions\. Plugins with their own GUI retain their normal interface\.

## 👆 Touch & swipe navigation

- **Swipe through popups:** browse Library, Recents, highlights, quotes, search results, favourites and search diagnostics\.
- **Navigate quotes naturally:** swipe vertically between quotes/highlights and horizontally between text pages\.
- **Browse category previews:** swipe a folder’s cover row to reveal more books without entering it\.
- **Switch launchers:** swipe left or right between Apps and Games\.
- **Keep your place:** layered book popups return you to the library folder and page you were browsing\.
- **Choose how to exit:** optionally require a long press to leave Slate\.

## 🔒 PIN\-pad lock

- **Optional screen lock:** set, change or reset your PIN\.
- **Quick toggle:** tap the lock icon to enable or disable PIN\-lock mode once a PIN is configured; enter your PIN to unlock a locked screen\.
- **Wrong\-PIN protection:** temporary lockout after repeated incorrect attempts\.
- **Custom lock messages:** choose your message, placement and alignment\.
- **Control feedback:** configure success messages and lock\-icon outlines\.
- **Settings within reach:** optionally long\-press the unlocked lock icon to open the complete Slate settings editor\.

## 🎨 Make it yours

- **Replace widget icons:** use your own SVG or PNG assets\.
- **Tune typography:** customise fonts and text sizes, including quotes and popup headers\.
- **Shape the interface:** adjust borders, outlines, spacing, rounded corners and night\-mode behaviour\.
- **Arrange your screen:** change widget size, position, popup header appearance and book\-grid layouts\.
- **Edit in place:** settings changes redraw the home interface without a sleep/wake cycle\.
- **Advanced controls:** detailed size, spacing and frame settings in a dedicated submenu\.

## 📥 Installation

1. Download the installable `slate.koplugin` ZIP from this repository’s **Releases** page\.
2. Extract it and copy the complete `slate.koplugin` folder into your KOReader `plugins` directory\. On Kindle: `/mnt/us/koreader/plugins/`\.
3. Restart KOReader and enable Slate in Plugin Management if needed\.
4. Open **Settings → Screen → Slate** to configure it\.
5. Under **Screen → Sleep Screen → Wallpaper**, select **Show Slate on sleep screen**\.

## 🛠️ First setup

- Set your **books directory** under **Library Button**; its subfolders become Categories\.
- Under **Random Quote**, run **Extract Highlighted Texts** to build your quote collection from saved KOReader highlights\.
- Set your location under **Weather Settings**\. No weather API key is required\.
- Choose your installed plugins under **Quick Launch → Select APPS / Select GAMES**\.
- Google Books support is optional: enter your own Books API key under **Book Descriptions**\.

Reading statistics use KOReader’s existing statistics database\. Background description downloads require connectivity and pause while the device sleeps\. A matching catalogue record may still have no description available\.

## 🙏 Credits & acknowledgements

Slate builds on the KOReader community’s work\. Thank you to the original authors whose code helped make it possible:

|Project                                                                              |Contribution to Slate                                                                                      |Upstream licence                                                                            |
|-------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
|[WeatherLockscreen — loeffner](https://github.com/loeffner/WeatherLockscreen)        |Weather lock-screen foundations and display code, adapted and extended for Slate.                          |[AGPL-3.0](https://github.com/loeffner/WeatherLockscreen/blob/main/LICENSE)                 |
|[PIN Pad Screenlock — Lena2309](https://github.com/Lena2309/pinpad_screenlock_plugin)|PIN-pad interface and locking behaviour, adapted for Slate.                                                |[MIT](https://github.com/Lena2309/pinpad_screenlock_plugin/blob/main/LICENSE.txt)           |
|[Random Quote — DenisovichDev](https://github.com/DenisovichDev/randomquote.koplugin)|Highlight extraction and random-quote foundations, expanded with search, favourites, tags and book filters.|[AGPL-3.0-or-later](https://github.com/DenisovichDev/randomquote.koplugin/blob/main/LICENSE)|
|[KOReader](https://github.com/koreader/koreader)                                     |Reader platform, UI components, document metadata, history and reading statistics.                         |[Upstream licence](https://github.com/koreader/koreader/blob/master/COPYING)                |

Lena2309 also credits [yogi81’s screenlock\_koreader\_plugin](https://github.com/yogi81/screenlock_koreader_plugin) as the foundation of their original PIN\-lock work\.

### 🌐 Data sources

- **Weather:** [Open\-Meteo](https://open-meteo.com/) — weather data under [CC BY 4\.0](https://creativecommons.org/licenses/by/4.0/)\. Its free hosted API is intended for noncommercial use\.
- **Book descriptions:** [Open Library](https://openlibrary.org/), [Google Books](https://developers.google.com/books) and [Wikipedia](https://www.wikipedia.org/)\. Description popups identify the source; retrieved content retains its applicable source terms\.

## 📜 Licence

Slate’s derivative plugin code is distributed under the **GNU Affero General Public License v3\.0**; see [LICENSE](LICENSE)\. Preserve upstream copyright, licence and modification notices\. Adapted PIN\-pad components retain their MIT notice; third\-party assets retain their applicable licences\.
