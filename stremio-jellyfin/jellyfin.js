import axios from "axios"
import os from "os"

export const server = process.env.JELLYFIN_SERVER
const user = process.env.JELLYFIN_USER
const password = process.env.JELLYFIN_PASSWORD
const device = os.hostname()
const itemsLimit = 20

export class JellyfinApi {

    async authenticate() {
        // The password never goes to the log. These three lines used to
        // interpolate it, which put the Jellyfin credential into `docker logs`
        // on every restart -- and this service restarts in a loop whenever
        // Jellyfin is unreachable or refusing it, so the log filled up with it.
        // A credential in a log survives the password being changed, is copied
        // into any bug report that pastes logs, and is readable by anything
        // that can reach the Docker API. Server and username are enough to
        // diagnose a login failure; whether the password is set at all is
        // visible from `docker inspect`'s env block.
        console.log(`Connecting to Jellyfin server: ${server} with username: ${user}`)
        this.auth = await axios.post(`${server}/Users/authenticatebyname`,
            {Username: user, Pw: password}, {
                headers: {
                    'Content-Type': 'application/json',
                    // Two things were wrong with this header, and Jellyfin 12
                    // accepts neither:
                    //
                    //   1. The trailing `""`, which left the header unparseable.
                    //      Jellyfin reads it into the session's `App`, and a
                    //      null `App` makes `authenticatebyname` throw inside
                    //      SessionManager.AuthenticateNewSessionInternal:
                    //      "Value cannot be null. (Parameter 'request.App')".
                    //      That is the 400 this service answered for every
                    //      username, including ones that do not exist -- which
                    //      is why it read as a server fault for so long.
                    //   2. The header NAME. Measured against this server, three
                    //      spellings behave three different ways:
                    //        X-Emby-Authorization -> 400, App never parsed
                    //        Authorization        -> 401 with a bad password,
                    //                                i.e. parsed, then rejected
                    //      so `Authorization` is the one that reaches the
                    //      credential check at all. That is what the web client
                    //      sends, captured from a live login.
                    //
                    // Note for whoever reads this next: a 401 from here now
                    // means the credential is wrong, and the log line below
                    // says exactly that. It is no longer the server's doing.
                    Authorization: `MediaBrowser Client="Jellyfin Stremio Addon", Device="${device}", DeviceId="${device}", Version="1.0.0.0"`
                }
            }).then(it => it.data)
            .catch(err => {
                if (err?.response) {
                    console.log(`Error caught while Jellyfin authentication, server response: '${err?.response?.status}' and data: '${err?.response?.data || "<empty>" }' (server: '${server}' with username: '${user}')`)
                } else {
                    console.log(`Error connecting to Jellyfin (server: '${server}' with username: '${user}'). Error message: '${err?.message}'`)
                    // anything else
                }
                console.info("Exiting. Please check your configuration and Jellyfin connection.")
                process.exit()
            })
        console.log(`Successfully connected to Jellyfin server: ${server}. Happy streaming.`)
        this.authorisationHeader = `MediaBrowser Client="Jellyfin Stremio Addon", Device="${device}", DeviceId="${device}", Version="1.0.0.0", Token="${this.auth.AccessToken}"`
    }

    async getItemById(itemId) {
        return axios.get(`${server}/Users/${this.auth.User.Id}/Items/${itemId}`,
            {
                headers: {
                    'Content-Type': 'application/json',
                    Authorization: this.authorisationHeader
                }
            })
    }

    async searchItems(skip, movie, searchTerm = null) {
        let firstItem = Number(skip) + 1
        // `IncludeItemTypes` must appear exactly ONCE in this URL. It used to be
        // baked into the base as `Movie,Series` and then appended again as
        // `Movie` or `Series`, and Jellyfin 12 mishandles the repeated parameter
        // whenever either occurrence is a comma-separated list: it drops the
        // filter and answers with the library's Studios instead of the type that
        // was asked for.
        //
        // Measured against this server on 2026-09-17, same library, same user:
        //   IncludeItemTypes=Movie                  -> 52 items, all Movie
        //   IncludeItemTypes=Movie,Series           -> 90 items (52 Movie, 38 Series)
        //   IncludeItemTypes=Movie,Series&...&Movie -> 226 items, 153 Studio + 47 Movie
        //
        // A Studio carries no ProviderIds.Imdb, so itemToMeta produced metas with
        // no `id` and a `type` of "studio" -- not one of the addon's declared
        // types -- and Stremio dropped every one of them. The addon stayed
        // healthy and answered 200 with a well-formed body, while the
        // "Jellyfin - Movie" and "Jellyfin - Series" rows rendered empty.
        const includeItemTypes = movie ? 'Movie' : 'Series'
        let itemsSearch = `${server}/Items?userId=${this.auth.User.Id}&hasImdb=true&Recursive=true&IncludeItemTypes=${includeItemTypes}&startIndex=${firstItem}&limit=${itemsLimit}&sortBy=SortName`
        if (searchTerm) {
            itemsSearch += `&searchTerm=${searchTerm}`
        }

        return axios.get(itemsSearch,
            {
                headers: {
                    'Content-Type': 'application/json',
                    Authorization: this.authorisationHeader
                }
            })
            .then(it => it.data.Items.map(it => this.getItemById(it.Id)))
    }

     getItemByImdbId(imdbId) {
        // The companion "Providers ID Items Search API" plugin this method
        // originally called is unmaintained and throws MissingMethodException
        // on current Jellyfin (its compiled ILibraryManager call no longer
        // matches the server's ABI). Do the lookup with Jellyfin's own
        // built-in Items endpoint instead: fetch items with ProviderIds and
        // filter client-side, since AnyProviderIdEquals is not a real filter
        // on this server version (it silently returns the unfiltered list).
        return axios.get(`${server}/Items?userId=${this.auth.User.Id}&Recursive=true&IncludeItemTypes=Movie,Series&Fields=ProviderIds`,
            {
                headers: {
                    'Content-Type': 'application/json',
                    Authorization: this.authorisationHeader
                }
            })
            .then(resp => resp.data.Items.filter(it => it.ProviderIds && it.ProviderIds.Imdb === imdbId))
            .then(matches => Promise.all(matches.map(it => this.getItemById(it.Id).then(r => r.data))))
    }

     getSeasonByParentItemIdAndSeasonNumber(itemId, seasonNumber) {
        return axios.get(`${server}/Shows/${itemId}/Seasons?userId=${this.auth.User.Id}`,
            {
                headers: {
                    'Content-Type': 'application/json',
                    Authorization: this.authorisationHeader
                }
            }).then(item => item.data)
    }

     getEpisodeByItemIdAndSeasonId(itemId, seasonId) {

        return axios.get(`${server}/Shows/${itemId}/Episodes?seasonId=${seasonId}&userId=${this.auth.User.Id}`,
            {
                headers: {
                    'Content-Type': 'application/json',
                    Authorization: this.authorisationHeader                }
            }).then(item => item.data)
    }
}
