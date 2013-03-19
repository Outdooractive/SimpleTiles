express = require("express")
nconf = require("nconf")
sqlite3 = require("sqlite3")
pg = require("pg").native
Client = require('pg').native.Client
path = require("path")
fs = require("fs")

app = module.exports = express.createServer()


if app.settings.env == "development"
    nconf.argv().env().file({ file: 'simple_tiles.cfg' })
else
    nconf.argv().env().file({ file: '/etc/simple_tiles.cfg' })

nconf.defaults({
    'port': 3000,
    'hostname': '127.0.0.1',
    'logfile': 'console',
    'path_prefix': '',
    'layers': []
})


if nconf.get('logfile') == 'console'
    app.use express.logger({ format: 'tiny' })
else
    logfile = fs.createWriteStream(nconf.get('logfile'), {flags: 'a'})
    app.use express.logger({ format: 'tiny', stream: logfile })

app.mbtiles_projects = {}


open_database = (current_name, current_tileset) ->
    if not current_name? or not current_tileset?
        return

    filename = current_tileset['filename']
    if not filename?
        return

    app.mbtiles_projects[current_name] = {}
    app.mbtiles_projects[current_name]['database'] = {}
    app.mbtiles_projects[current_name]['format']= {}
    app.mbtiles_projects[current_name]['db_type'] = {}

    if current_tileset['default_tile_path']?
        app.mbtiles_projects[current_name]['default_tile'] = fs.readFileSync(current_tileset['default_tile_path'])

    zoom_range = current_tileset['zoom_range']
    if not zoom_range? or zoom_range.length == 0
        zoom_range = [0..18]

    if (filename.indexOf("pg:") != -1)
        client = new pg.Client(filename);
        client.connect();

        for current_zoom in zoom_range
            app.mbtiles_projects[current_name]['database'][current_zoom] = client
            app.mbtiles_projects[current_name]['db_type'][current_zoom] = 'pg'

        client.query "SELECT value FROM metadata WHERE name='format'", (error, result) ->
            if error != null
                console.log error
                return

            if result.rows.length > 0
                row = result.rows[0]
                for current_zoom in zoom_range
                    app.mbtiles_projects[current_name]['format'][current_zoom] = row.value
            else
                console.log "- Missing format metadata in the '#{current_name}' layer' [#{zoom_range}], assuming 'png'..."
                for current_zoom in zoom_range
                    app.mbtiles_projects[current_name]['format'][current_zoom] = 'png'

            console.log "- Layer '#{current_name}' [#{zoom_range}] (#{filename}) uses '#{app.mbtiles_projects[current_name]['format'][zoom_range[0]]}' image tiles"

    else
        if filename[0] != '/'
            filename = path.join( process.cwd(), filename)

        db = new sqlite3.Database filename, sqlite3.OPEN_READONLY, (error) ->
            if error?
                console.log "Error opening database at '#{filename}'"
                console.log error
                process.exit 1

            for current_zoom in zoom_range
                app.mbtiles_projects[current_name]['database'][current_zoom] = db
                app.mbtiles_projects[current_name]['db_type'][current_zoom] = 'sqlite'

            db.run("PRAGMA cache_size = 20000")
            db.run("PRAGMA temp_store = memory")

            db.get "SELECT value FROM metadata WHERE name='format'", (error, row) ->
                if error != null
                    console.log error
                    process.exit 1

                if row?
                    for current_zoom in zoom_range
                        app.mbtiles_projects[current_name]['format'][current_zoom] = row['value']
                else
                    console.log "- Missing format metadata in the '#{current_name}' layer' [#{zoom_range}], assuming 'png'..."
                    for current_zoom in zoom_range
                        app.mbtiles_projects[current_name]['format'][current_zoom] = 'png'

                console.log "- Layer '#{current_name}' [#{zoom_range}] (#{filename}) uses '#{app.mbtiles_projects[current_name]['format'][zoom_range[0]]}' image tiles"


layers = nconf.get("layers")
for current_layer in layers
    current_name = current_layer['name']
    current_files = current_layer['files']
    if not current_files? or not current_name? or current_files.length == 0
        console.log "Error loading project '#{current_name}', continuing..."
        continue

    # Connection to the mbtiles db
    for current_tileset in current_files
        open_database(current_name, current_tileset)


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


# Deliver tiles
app.get "#{nconf.get('path_prefix')}/:project/:zoom/:x/:y.:format", (req, res) ->
    project = app.mbtiles_projects[req.params.project]
    if not project?
        res.send(404)
        return

    zoom = parseInt(req.params.zoom, 10)
    x = parseInt(req.params.x, 10)
    y = parseInt(req.params.y, 10)

    # Flip the y coordinate
    y = Math.pow(2, zoom) - 1 - y

    format = project['format'][zoom]
    if req.params.format != format
        if project['default_tile']?
            res.contentType("png")
            res.send project['default_tile']
         else
            res.send(404)
        return

    db = project['database'][zoom]
    if not db?
        res.send(500)
        return

    db_type = project['db_type'][zoom]
    if db_type == 'sqlite'
        db.get "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", zoom, x, y, (error, row) ->
            if error != null or not row?
                if project['default_tile']?
                    res.contentType(format)
                    res.send project['default_tile']
                else
                    res.send(404)
                return

            res.contentType(format)
            res.send row['tile_data']

    else if db_type == 'pg'
        db.query "SELECT tile_data FROM tiles WHERE zoom_level=$1 AND tile_column=$2 AND tile_row=$3", [zoom, x, y], (error, result) ->
            if error != null or result.rows.length == 0
                if project['default_tile']?
                    res.contentType(format)
                    res.send project['default_tile']
                else
                    res.send(404)
                return

            res.contentType(format)
            res.send result.rows[0].tile_data


# Start the server
app.listen nconf.get('port'), nconf.get('hostname'), ->
    console.log "SimpleTiles server listening on port %d (host %s) in %s mode", app.address().port, app.address().address, app.settings.env
