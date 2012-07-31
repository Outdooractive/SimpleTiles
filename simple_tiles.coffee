express = require("express")
nconf = require("nconf")
sqlite3 = require("sqlite3")
path = require("path")

app = module.exports = express.createServer()
app.use express.logger({ format: 'tiny' })

app.mbtiles_projects = {}


nconf.argv().
    env().
    file({ file: '/etc/simple_tiles.cfg' }).
    file({ file: 'simple_tiles.cfg' })

nconf.defaults({
    'port': 3000,
    'hostname': '127.0.0.1',
    'layers': []
})


layers = nconf.get("layers")
for current_layer in layers
    current_name = current_layer['name']
    current_tileset = current_layer['tileset']
    if not current_tileset? or not current_name?
        continue

    app.mbtiles_projects[current_name] = {}

    # Connection to the mbtiles db
    if current_tileset[0] != '/'
        current_tileset = path.join( process.cwd(), current_tileset)

    db = new sqlite3.Database current_tileset, sqlite3.OPEN_READONLY, (error) ->
        if error?
            console.log error
            process.exit 1

    app.mbtiles_projects[current_name]['database'] = db

    db.get "SELECT value FROM metadata WHERE name='format'", (error, row) ->
        if error != null
            console.log error
            process.exit 1

        if row?
            app.mbtiles_projects[current_name]['format'] = row['value']
        else
            console.log "Missing format metadata in the '#{current_name}' layer' - exiting..."
            process.exit 1

        console.log "- Layer '#{current_name}' (#{current_tileset}) uses '#{app.mbtiles_projects[current_name]['format']}' image tiles"


# SimpleTiles
app.configure ->
    app.use app.router


 app.configure "development", ->
    app.use express.errorHandler(
        dumpExceptions: true
        showStack: true
    )


app.configure "production", ->
    app.use express.errorHandler()


app.get "/:project/:zoom/:x/:y.:format", (req, res) ->
    project = app.mbtiles_projects[req.params.project]
    if not project?
        res.send(404)
        return

    format = project['format']
    if req.params.format != format
        res.send(404)
        return

    zoom = parseInt(req.params.zoom, 10)
    x = parseInt(req.params.x, 10)
    y = parseInt(req.params.y, 10)

    db = project['database']
    db.get "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_row=? AND tile_column=?", zoom, y, x, (error, row) ->
        if error != null or not row?
            res.send(404)
            return

        res.contentType(format)
        res.send row['tile_data']

app.listen nconf.get('port'), nconf.get('hostname'), ->
    console.log "SimpleTiles server listening on port %d (host %s) in %s mode", app.address().port, app.address().address, app.settings.env
