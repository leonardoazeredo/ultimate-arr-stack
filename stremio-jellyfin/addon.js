// noinspection JSPotentiallyInvalidConstructorUsage

import Promise from "es6-promise"
import {addonBuilder} from "stremio-addon-sdk"
import {JellyfinApi, server} from "./jellyfin.js";
import {manifest} from "./manifest.js";

const jellyfin = new JellyfinApi()
await jellyfin.authenticate()

function stringToUuid(plainStringUuid) {
    return plainStringUuid.replace(
        /(.{8})(.{4})(.{4})(.{4})(.{12})/g,
        "$1-$2-$3-$4-$5"
    )
}

// How long a Stremio client may reuse a stream answer, in seconds.
//
// The addon sent none, so the client applied its own default -- and a cached
// answer then outlives the thing that changed it. Measured 2026-09-22: this
// addon stopped serving episodes the library does not hold at 14:00, and the
// same client was still playing the old fallback at 23:00 because it had the
// wrong answer cached. The same delay hides an episode the drain has just
// delivered, which is why the number is sent explicitly rather than assumed.
//
// 300 and not 0: every request makes this addon scan the whole Jellyfin library
// (getItemByImdbId lists every Movie and Series to filter by IMDb id), so
// answering every navigation from scratch costs the NAS a full scan per episode
// opened. Five minutes caps how stale an answer can be while still absorbing a
// burst of re-opens.
const STREAM_CACHE_MAX_AGE = 300

let builder = new addonBuilder(manifest)

function itemToMeta(item) {
    return {
        id: item.ProviderIds.Imdb,
        type: item.Type.toLowerCase(),
        name: item.Name,
        poster: `${server}/Items/${item.Id}/Images/Primary`
    }
}

builder.defineCatalogHandler(async ({type, id, extra}) => {
    console.log("request for catalogs: " + type + " " + id)
    return Promise.resolve({
        metas: await Promise.all(await jellyfin.searchItems(extra.skip || 0, type === 'movie', extra.search))
            .then(it => it.map(e => itemToMeta(e.data)))
    })
})

builder.defineMetaHandler(({type, id}) => {
    console.log("request for meta: " + type + " " + id)
    return Promise.resolve({meta: null})
})

builder.defineStreamHandler(async ({type, id}) => {
    console.log("request for streams: " + type + " " + id)
    let items = []
    if (id.includes(":")) {

        // resolve actual episode
        const resolvedId = id.split(":")
        const seriesId = resolvedId[0]
        const season = Number(resolvedId[1])
        const episode = Number(resolvedId[2])

        const seriesItem = (await jellyfin.getItemByImdbId(seriesId))[0]
        if ((seriesItem === undefined))
            return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})

        // Exact match, or no stream.
        //
        // Both lookups used to end in a fallback -- `?? seasons[0]` and
        // `?? episodes[0]` -- added on 2026-09-11 so that an unnumbered
        // Specials season would still resolve. The cost was paid by every
        // series the library holds only in part: Stremio asks for each episode
        // of the series Cinemeta lists, and a request for an episode that is
        // not here was answered from the first season and the first episode
        // instead of being refused. Measured 2026-09-22 on a library holding
        // only Dragon Ball Super S1 and S2: the addon returned a Jellyfin
        // stream for S03E19 and S05E55, which do not exist, and the streams it
        // served were S01E01 and S01E01 -- a wrong episode plays, and nothing
        // in the UI says the request was never satisfied.
        //
        // Checked before removing them: this library has 165 seasons and not
        // one has a null IndexNumber, and it holds no Specials season at all,
        // so the fallback protected nothing here. A season or episode the
        // library does not have now returns no stream, which is what the
        // viewer should see.
        //
        // Those refusals are `{streams: []}`, the shape the resource declares.
        // They used to be a bare `[]`, which is not what a stream handler
        // returns; every refusal path in this file now answers in the same
        // shape as the paths that find something.
        const seasons = (await jellyfin.getSeasonByParentItemIdAndSeasonNumber(seriesItem.Id, season)).Items
        if (!seasons || seasons.length === 0)
            return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})
        const seasonItem = seasons.find(it => it.IndexNumber === season)
        if (seasonItem === undefined)
            return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})

        const episodes = (await jellyfin.getEpisodeByItemIdAndSeasonId(seriesItem.Id, seasonItem.Id)).Items
        if (!episodes || episodes.length === 0)
            return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})
        const episodeItem = episodes.find(it => it.IndexNumber === episode)
        if (episodeItem === undefined)
            return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})

        const actualEpisodeItem = await jellyfin.getItemById(episodeItem.Id).then(it => it.data)

        items = [actualEpisodeItem]

    } else
        items = await jellyfin.getItemByImdbId(id)

    if (items === undefined || items.length === 0)
        return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})

    const item = items[0]
    const itemId = stringToUuid(item.Id)

    if (!(itemId === undefined)) {
        const stream = {
            url: `${server}/videos/${itemId}/stream.mkv?static=true&api_key=${jellyfin.auth.AccessToken}&mediaSourceId=${item.MediaSources[0].Id}`,
            name: 'Jellyfin',
            description: item.MediaSources[0].MediaStreams[0].DisplayTitle
        }
        return Promise.resolve({streams: [stream], cacheMaxAge: STREAM_CACHE_MAX_AGE})
    }

    console.log(`Cant find stream for: ${id}`)
    return Promise.resolve({streams: [], cacheMaxAge: STREAM_CACHE_MAX_AGE})
})

export const addonInterface = builder.getInterface()
