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
            return Promise.resolve([])

        // Season 0 is Jellyfin's "Specials", and a season the library does not
        // have yet simply is not in this list. The lookup used to find the
        // season whose IndexNumber matches, which returns undefined for both of
        // those, and every request for them then failed as "no streams" --
        // which is what a viewer sees as an episode that refuses to play.
        // Measured 2026-09-11 on a library whose only season for one series is
        // `Specials (IndexNumber=0)`: asking for 1:1 returned nothing, and this
        // fallback is what makes Stremio's usual first request work.
        //
        // Only when there is no match AND no seasons at all is the item
        // genuinely unresolvable, so that case still returns an empty list.
        const seasons = (await jellyfin.getSeasonByParentItemIdAndSeasonNumber(seriesItem.Id, season)).Items
        if (!seasons || seasons.length === 0)
            return Promise.resolve([])
        const seasonItem = seasons.find(it => it.IndexNumber === season) ?? seasons[0]

        const episodes = (await jellyfin.getEpisodeByItemIdAndSeasonId(seriesItem.Id, seasonItem.Id)).Items
        if (!episodes || episodes.length === 0)
            return Promise.resolve([])
        // Specials carry no IndexNumber in this library, so falling back to the
        // first entry is the only way an episode request can resolve there.
        const episodeItem = episodes.find(it => it.IndexNumber === episode) ?? episodes[0]

        const actualEpisodeItem = await jellyfin.getItemById(episodeItem.Id).then(it => it.data)

        items = [actualEpisodeItem]

    } else
        items = await jellyfin.getItemByImdbId(id)

    if (items === undefined || items.length === 0)
        return Promise.resolve([])

    const item = items[0]
    const itemId = stringToUuid(item.Id)

    if (!(itemId === undefined)) {
        const stream = {
            url: `${server}/videos/${itemId}/stream.mkv?static=true&api_key=${jellyfin.auth.AccessToken}&mediaSourceId=${item.MediaSources[0].Id}`,
            name: 'Jellyfin',
            description: item.MediaSources[0].MediaStreams[0].DisplayTitle
        }
        return Promise.resolve({streams: [stream]})
    }

    console.log(`Cant find stream for: ${id}`)
    return Promise.resolve({streams: []})
})

export const addonInterface = builder.getInterface()
