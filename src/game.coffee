wrap_angle = (ang) ->
    return ((ang + Math.PI) %% (2 * Math.PI)) - Math.PI

sign = (x) -> if x == 0 then 0 else x / Math.abs(x)

infill_object = (dest, src) ->
    for key, val of src
        if key not of dest
            dest[key] = val
    return dest

# Standard vector class for geo
class Vector
    constructor: (@x, @y) ->

    # Standard ops
    plus: (o) -> new Vector @x + o.x, @y + o.y
    minus: (o) -> new Vector @x - o.x, @y - o.y
    times: (s) -> new Vector @x * s, @y * s
    divided_by: (s) -> new Vector @x / s, @y / s
    magnitude: -> Math.sqrt @x * @x + @y * @y
    unit: -> @divided_by @magnitude()
    dir: -> Math.atan2 @y, @x
    copy: (o) -> @x = o.x; @y = o.y
    clone: -> new Vector @x, @y

    # In-place ops
    plus_inplace: (o) -> @x += o.x; @y += o.y; return
    minus_inplace: (o) -> @x -= o.x; @y -= o.y; return
    times_inplace: (s) -> @x *= s; @y *= s; return
    divided_by_inplace: (s) -> @x /= s; @y /= s; return
    unit_inplace: -> @divided_by_inplace @magnitude()

Vector.fromPolar = (magnitude, angle) ->
    new Vector Math.cos(angle) * magnitude, Math.sin(angle) * magnitude

# RenderContexts know about canvases and contexts
class RenderContext
    constructor: (@canvas, @ctx) ->
        @stone_asset = @ctx.createPattern(document.getElementById('stone-asset'), 'repeat')
        @stone_top_asset = @ctx.createPattern(document.getElementById('stone-top-asset'), 'repeat')

class AiWorker
    constructor: (@character, program) ->
        blob = new Blob [program], {type: 'text/javascript'}
        @worker = new Worker URL.createObjectURL blob
        @ready = true

        @worker.onmessage = (e) =>
            e = e.data
            switch e.type
                when 'ready'
                    @ready = true
                when 'turn'
                    @character.angular_dir = e.dir
                when 'move'
                    @character.movement_dir = e.dir
                    @character.moving = true
                when 'strike'
                    @character.strike()
                when 'start_shooting'
                    @character.start_shooting()
                when 'stop_shooting'
                    @character.stop_shooting()
                when 'nock'
                    @character.nock()
                when 'loose'
                    @character.loose()
                when 'cast'
                    @character.cast new Vector e.target.x, e.target.y
                when 'cancel_casting'
                    @character.cancel_casting()

    tick: (info) ->
        if @ready
            @worker.postMessage {
                characters: info.characters.filter((x) -> x.health > 0).map (x) => x.create_reader(@character.allegiance)
                bullets: info.bullets.filter((x) -> x.alive).map (x) -> x.create_reader()
                spells: info.spells.filter((x) -> x.alive).map (x) -> x.create_reader()
                walls: info.walls.map (x) -> x.create_reader()
                main_character: @character.create_reader(@character.allegiance)
            }

            @ready = false

    terminate: -> @worker.terminate()

# Every Character is a cylinder with a height and a radius.
class Character
    constructor: (@height, @radius, @pos = new Vector(0, 0), @allegiance, @ai = DUMBO, @colors = {}) ->
        @velocity = new Vector(0, 0)
        @hitbox_radius = @radius * 1.5

        @ai_runner = new AiWorker @, create_ai_from_template @ai
        @player_controlled = false

        infill_object @colors, DEFAULT_COLORS

        @dir = 0
        @age = 0

        @movement_dir = null
        @moving = false
        @walking_acceleration = 0.3

        @angular_dir = 0
        @angular_velocity = 0
        @angular_acceleration = 0.03

        @health = @max_health = 100

    create_reader: (allegiance) -> {
        @pos,
        @dir,
        @velocity,
        @angular_velocity,
        @health,
        @player_controlled,
        allegiance: @allegiance is allegiance,
        @type_string
    }

    damage: (damage) ->
        @health -= damage
        @health = Math.max @health, 0

    tick: (info) ->
        unless @player_controlled
            @ai_runner.tick info

        @age += 1

        # Velocity
        if @moving
            @velocity.plus_inplace Vector.fromPolar @walking_acceleration, @movement_dir

        @angular_velocity *= ANGULAR_FRICTION
        @angular_velocity += @angular_acceleration * Math.max -1, Math.min 1, @angular_dir
        @dir += @angular_velocity
        @dir = wrap_angle(@dir)

        @pos.plus_inplace @velocity
        @velocity.times_inplace FRICTION

        return

    # Pos is our position on the ground,
    # but many UI interactions instead want to deal with
    # our heart location, in the middle of our torso
    heart: ->
        @pos.minus new Vector(0, @height * 3 / 4)

    render_pants: (render_context) ->
        {ctx, canvas} = render_context

        # Our legs are the same height as our torso.
        pants_height = @height * (1 - TORSO_PROPORTION)
        right_pants_height = pants_height
        left_pants_height = pants_height

        # If we are walking, our legs are different
        # heights
        if @moving
            # Determine our parity
            if Math.floor(@age / WALKING_PERIOD) % 2 is 0
                right_pants_height *= WALKING_RATIO
            else
                left_pants_height *= WALKING_RATIO

        # Legs take up exactly half of the linear area
        # of our bottom, so they are each 1/2 radius in width.
        pants_width = @radius / 2

        # @pos it the center of our bottom.
        # This means our pants centers are at:
        right_leg_center = @pos.minus new Vector(pants_width, pants_height)
        left_leg_center = @pos.minus new Vector(-pants_width, pants_height)

        # Pants color
        ctx.strokeStyle = @colors.pants
        ctx.lineWidth = pants_width
        ctx.lineCap = 'round'

        # Draw the rectangles
        ctx.beginPath()
        ctx.moveTo right_leg_center.x, right_leg_center.y
        ctx.lineTo right_leg_center.x, right_leg_center.y + right_pants_height
        ctx.stroke()

        ctx.beginPath()
        ctx.moveTo left_leg_center.x, left_leg_center.y
        ctx.lineTo left_leg_center.x, left_leg_center.y + left_pants_height
        ctx.stroke()

    render_torso: (render_context) ->
        {ctx, canvas} = render_context

        torso_height = @height * TORSO_PROPORTION
        torso_width = @radius * 2

        # Corner is the top-right of our entire hitbox
        torso_corner = @pos.minus new Vector(@radius, @height)
        torso_bottom_center = @pos.minus new Vector(0, @height - torso_height)
        torso_top_center = @pos.minus new Vector(0, @height)

        ctx.fillStyle = @colors.torso

        ctx.fillRect(
            torso_corner.x,
            torso_corner.y,
            torso_width,
            torso_height
        )

        ctx.beginPath()
        ctx.arc(
            torso_bottom_center.x,
            torso_bottom_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

        ctx.fillStyle = @colors.torso_top

        ctx.beginPath()
        ctx.arc(
            torso_top_center.x,
            torso_top_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

    left_arm_vector: ->
        return Vector.fromPolar(@height * 0.3, @dir).plus(
            new Vector(0, @height / 4)
        )

    right_arm_vector: ->
        return Vector.fromPolar(@height * 0.3, @dir).plus(
            new Vector(0, @height / 4)
        )

    render_left_item: ->
    render_right_item: ->

    # Arms and torso are grouped together
    # so that arms can control when the torso is drawn.
    # This is so that one arm can appear to be "behind"
    # the body for appropriate directions.
    render_arms_and_torso: (render_context) ->
        {ctx, canvas} = render_context

        arm_center = @pos.minus new Vector(0, @height)

        # Determine which arm is "behind"
        right_arm = arm_center.plus Vector.fromPolar(@radius, @dir + Math.PI / 2)
        left_arm = arm_center.plus Vector.fromPolar(@radius, @dir - Math.PI / 2)

        # Determine the hand positions
        right_arm_dest = right_arm.plus @right_arm_vector()
        left_arm_dest = left_arm.plus @left_arm_vector()

        if right_arm.y < left_arm.y
            back_arm = right_arm
            back_arm_dest = right_arm_dest
            front_arm = left_arm
            front_arm_dest = left_arm_dest
        else
            back_arm = left_arm
            back_arm_dest = left_arm_dest
            front_arm = right_arm
            front_arm_dest = right_arm_dest

        # Draw the "behind" item
        if Math.sin(@dir) < 0 #right_arm_dest.y < @pos.y
            if left_arm is back_arm
                @render_left_item(render_context, left_arm_dest)
                @render_right_item(render_context, right_arm_dest)
            else
                @render_right_item(render_context, right_arm_dest)
                @render_left_item(render_context, left_arm_dest)
        #if left_arm_dest.y < @pos.y

        # Draw the "behind" arm
        ctx.strokeStyle = @colors.arms
        ctx.lineWidth = @radius / 2
        ctx.lineCap = 'round'

        ctx.beginPath()
        ctx.moveTo back_arm.x, back_arm.y
        ctx.lineTo back_arm_dest.x, back_arm_dest.y
        ctx.stroke()

        # Draw torso and head
        @render_torso(render_context)
        @render_head(render_context)

        # Draw the "in front" arm
        ctx.strokeStyle = @colors.arms
        ctx.lineWidth = @radius / 2
        ctx.lineCap = 'round'

        ctx.beginPath()
        ctx.moveTo front_arm.x, front_arm.y
        ctx.lineTo front_arm_dest.x, front_arm_dest.y
        ctx.stroke()

        # Draw "front" item
        if Math.sin(@dir) >= 0 #right_arm_dest.y >= @pos.y
            if left_arm is back_arm
                @render_left_item(render_context, left_arm_dest)
                @render_right_item(render_context, right_arm_dest)
            else
                @render_right_item(render_context, right_arm_dest)
                @render_left_item(render_context, left_arm_dest)

    render_hat: ->

    render_head: (render_context) ->
        {ctx, canvas} = render_context

        head_center = @pos.minus new Vector(0, @height + @radius)

        ctx.fillStyle = @colors.head

        ctx.beginPath()
        ctx.arc(
            head_center.x,
            head_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

        #@render_hat render_context, head_center

    render_shadow: (render_context) ->
        {ctx, canvas} = render_context

        ctx.globalAlpha = 0.5

        ctx.fillStyle = '#000'
        ctx.beginPath()
        ctx.arc(
            @pos.x, @pos.y,
            @hitbox_radius,
            0, 2 * Math.PI
        )
        ctx.fill()

        ctx.globalAlpha = 1

    render: (render_context) ->
        @render_shadow(render_context)
        @render_pants(render_context)
        @render_arms_and_torso(render_context)
        @render_health_bar(render_context)
        @render_emblem(render_context)

    render_health_bar: (render_context) ->
        {ctx, canvas} = render_context

        pos = @pos.minus new Vector(@hitbox_radius, @height + @radius + 20)

        ctx.fillStyle = '#F00'
        ctx.fillRect(
            pos.x, pos.y, 3 * @radius, 5
        )

        ctx.fillStyle = '#0F0'
        ctx.fillRect(
            pos.x, pos.y, 3 * @radius * @health / @max_health, 5
        )

    render_emblem: (render_context) ->
        {ctx, canvas} = render_context

        center = @pos.minus new Vector @hitbox_radius, @height + @radius + 20 - 2.5

        if @allegiance
            ctx.fillStyle = '#FFF'
        else
            ctx.fillStyle = '#000'

        ctx.beginPath()
        ctx.arc(center.x, center.y, 5, 0, 2 * Math.PI)
        ctx.fill()

        if @player_controlled
            ctx.fillStyle = '#0F0'
        else if @allegiance
            ctx.fillStyle = '#00F'
        else
            ctx.fillStyle = '#F00'
        ctx.beginPath()
        ctx.moveTo center.x, center.y + 5
        for x in [1..3]
            point = center.plus Vector.fromPolar 5, x * Math.PI * 2 / 3 + Math.PI / 2
            ctx.lineTo point.x, point.y
        ctx.fill()

class Knight extends Character
    constructor: ->
        super

        @type = Knight
        @type_string = 'knight'

        @strike_age = 0
        @striking_forward = false
        @striking_sidways = false

        @walking_acceleration = 0.2
        @angular_acceleration = 0.04

        @colors.torso = '#78A'
        @colors.torso_top = '#568'
        @colors.head = '#AAF'

        @health = @max_health = 100

    create_reader: ->
        reader = super
        reader.strike_age = @strike_age
        reader.striking_forward = @striking_forward
        reader.striking_sideways = @striking_sideways
        return reader

    damage: (damage) ->
        if @striking_sidweays
            @health -= damage
        else if @striking_forward
            @health -= damage / 2
        else
            @health -= damage / 3

    tick: ->
        super

        if @striking_forward and @age - @strike_age > 10
            @striking_forward = false
            @striking_sideways = true

        if @striking_sideways and @age - @strike_age > 60
            @striking_sideways = false

    left_arm_vector: ->
        if @striking_sideways
            return Vector.fromPolar(@height * 0.3, -Math.PI / 4 * Math.min(1, (@age - @strike_age - 10) / 5) + @dir).plus(
                new Vector(0, @height / 4)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    right_arm_vector: ->
        if @striking_forward
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4 * (1 - (@age - @strike_age) / 10))
            )
        else if @striking_sideways
            return Vector.fromPolar(@height * 0.3, @dir + Math.min(1, (@age - @strike_age - 10) / 5) * Math.PI / 2)
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    # Shield
    render_left_item: (render_context, position) ->
        {ctx, canvas} = render_context

        # Shield is a rectangle
        shield_width = @radius * 2
        shield_height = @height * SHIELD_RATIO

        shield_top_center = position.minus new Vector 0, shield_height / 2
        shield_starting_point = shield_top_center.minus Vector.fromPolar shield_width / 2, @dir + Math.PI / 2

        corners = [
            shield_starting_point,
            shield_starting_point.plus(Vector.fromPolar(shield_width, @dir + Math.PI / 2)),
            shield_starting_point.plus(Vector.fromPolar(shield_width, @dir + Math.PI / 2)).plus(new Vector(0, shield_height)),
            shield_starting_point.plus(new Vector(0, shield_height))
        ]

        ctx.fillStyle = '#555'
        ctx.strokeStyle = '#888'
        ctx.lineWidth = 2
        ctx.lineJoin = 'bevel'
        ctx.beginPath()
        ctx.moveTo(corners[0].x, corners[0].y)
        for corner in corners
            ctx.lineTo corner.x, corner.y
        ctx.lineTo(corners[0].x, corners[0].y)
        ctx.fill()
        ctx.stroke()

    # Sword
    render_right_item: (render_context, position) ->
        {ctx, canvas} = render_context

        # Sword is a line
        if @striking_forward
            sword_dest = position.plus(new Vector(0, -@height/2 * (1 - (@age - @strike_age) / 10))).plus(
                Vector.fromPolar(@radius + 1.5 * (@age - @strike_age) / 10 * @radius, @dir)
            )
        else if @striking_sideways
            sword_dest = position.plus(
                Vector.fromPolar(@radius * 2.5, @dir + Math.min(1, (@age - @strike_age - 10) / 5) * Math.PI / 2)
            )
        else
            sword_dest = position.plus(new Vector(0, -@height/2)).plus(
                Vector.fromPolar(@radius, @dir)
            )

        ctx.strokeStyle = '#999'
        ctx.lineWidth = 5
        ctx.beginPath()
        ctx.moveTo(position.x, position.y)
        ctx.lineTo(sword_dest.x, sword_dest.y)
        ctx.stroke()

    strike: ->
        unless @striking_forward or @striking_sideways
            @strike_age = @age
            @striking_forward = true

SPELL_RADIUS = 100
class Particle
    constructor: (center, gen_proportion) ->
        @pos = center.plus Vector.fromPolar Math.random() * SPELL_RADIUS * gen_proportion, Math.random() * 2 * Math.PI
        @radius = ((Math.random() + 0.5) * 10 + 10) * gen_proportion
        @height = 0
        @speed = Math.random() * 10
        @age = 0

        @r = 255
        @g = 255
        @b = 255

    tick: ->
        @age += 1
        @height += @speed

        @r *= (0.95 + Math.random() * 0.05)
        @g *= 0.8
        @b *= 0.5

    render: (render_context) ->
        {ctx, canvas} = render_context
        ctx.fillStyle = "rgb(#{Math.round(@r)}, #{Math.round(@g)}, #{Math.round(@b)})"
        ctx.beginPath()
        ctx.arc(@pos.x, @pos.y - @height, @radius / Math.sqrt(@age), 0, 2 * Math.PI)
        ctx.fill()

class Spell
    constructor: ->
        @pos = null
        @age = 0
        @burning = false
        @alive = false
        @orientation = 0
        @particles = []

    create_reader: -> {@pos, @age, @burning}

    reset: (position) ->
        @pos = position
        @age = 0
        @alive = true
        @burning = false
        @orientation = Math.random() * 2 * Math.PI
        @particles = []

    tick: ->
        return unless @alive
        @age += 1

        if @age > 270
            @alive = false
            @burning = false
        else if @age > 90
            @burning = true
            @particles.forEach (p) -> if p.radius / Math.sqrt(p.age) > 4 then p.tick()
            age_proportion = Math.sqrt 1 - (@age - 90) / 180
            for [1...Math.floor((Math.random() * 4 + 3) * age_proportion)]
                @particles.push new Particle(@pos, age_proportion)

    render: (render_context) ->
        return unless @alive

        {ctx, canvas} = render_context

        ctx.strokeStyle = '#F00'
        ctx.lineWidth = 2
        ctx.beginPath()
        ctx.arc(@pos.x, @pos.y, SPELL_RADIUS, 0, 2 * Math.PI)

        # Pentagram
        if @burning
            ctx.globalAlpha = 0.8 * (1 - (@age - 90) / 180)
            ctx.fillStyle = '#000'
            ctx.fill()

            ctx.globalAlpha = 0.8
            for particle in @particles
                if particle.radius / Math.sqrt(particle.age) > 4
                    particle.render render_context
            ctx.globalAlpha = 1
        else
            ctx.stroke()
            ctx.beginPath()
            new_pos = @pos.plus(Vector.fromPolar(SPELL_RADIUS, @orientation))
            ctx.moveTo new_pos.x, new_pos.y

            proportion = @age / 90
            limit = Math.floor proportion * 6
            excess = proportion * 6 - limit

            for i in [0..limit]
                new_pos = @pos.plus(Vector.fromPolar(SPELL_RADIUS, i * Math.PI * 4 / 5 + @orientation))
                ctx.lineTo new_pos.x, new_pos.y

            # Last one
            last_point = @pos.plus(Vector.fromPolar(SPELL_RADIUS, limit * Math.PI * 4 / 5 + @orientation))
            next_point = @pos.plus(Vector.fromPolar(SPELL_RADIUS, (limit + 1) * Math.PI * 4 / 5 + @orientation))

            excess_point = last_point.times(1 - excess).plus(next_point.times(excess))
            ctx.lineTo excess_point.x, excess_point.y

            ctx.stroke()

class Mage extends Character
    constructor: ->
        super

        @type = Mage
        @type_string = 'mage'

        @colors.torso = '#53F'
        @colors.torso_top = '#217'
        @colors.arms = @colors.pants = '#217'

        @walking_acceleration = 0.15
        @angular_acceleration = 0.01

        @casting = false
        @casting_age = 0

        @spell = new Spell()

    damage: ->
        super
        if @health <= 0
            @spell.alive = false

    tick: ->
        super

        if @casting and not @spell.alive
            @casting = false
            @walking_acceleration = 0.15

        return

    create_reader: ->
        reader = super
        reader.casting = @casting
        reader.casting_age = @casting_age
        return reader

    cast: (position) ->
        if @spell.burning or @casting or @health <= 0 then return

        @casting = true
        @casting_age = @age
        @walking_acceleration = 0

        @spell.reset position

        return @spell

    cancel_casting: ->
        @casting = false
        @walking_acceleration = 0.15
        unless @spell.burning
            @spell.alive = false

    left_arm_vector: ->
        if @casting
            proportion = Math.min 1, (@age - @casting_age) / 60

            return Vector.fromPolar(@height * 0.3 * (1 - proportion), @dir).plus(
                new Vector(0, @height * (0.25 + 0.25 * proportion))
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    render_hat: (render_context, position) ->
        {ctx, canvas} = render_context

        ctx.fillStyle = '#006'
        left = position.plus(new Vector(-@radius - 1, 0))
        right = position.plus(new Vector(@radius + 1, 0))
        top = position.minus(new Vector(0, @radius * 3))

        ctx.beginPath()
        ctx.arc top.x, top.y, top.minus(left).magnitude(), right.minus(top).dir(), left.minus(top).dir()
        ctx.lineTo top.x, top.y
        ctx.fill()

    right_arm_vector: ->
        if @casting
            proportion = Math.min 1, (@age - @casting_age) / 60
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height * (0.25 - 0.5 * proportion))
            )
        else
            super

    render_right_item: (render_context, position) ->
        top_position = position.minus(new Vector(0, @height / 2))
        bottom_position = position.plus(new Vector(0, @height / 2))

        {canvas, ctx} = render_context

        ctx.strokeStyle = 'brown'
        ctx.lineWidth = 5

        ctx.beginPath()
        ctx.moveTo top_position.x, top_position.y
        ctx.lineTo bottom_position.x, bottom_position.y
        ctx.stroke()

        ctx.fillStyle = 'red'
        ctx.beginPath()
        ctx.arc(top_position.x, top_position.y, 5, 0, 2 *Math.PI)
        ctx.fill()

BOW_HEIGHT = 20
BOW_COLOR = 'brown'
BOWSTRING_COLOR = 'white'
BOW_THICKNESS = 5
ARROW_VELOCITY = 10
ARROW_LENGTH = 25
class Archer extends Character
    constructor: ->
        super

        @type = Archer
        @type_string = 'archer'

        @loading = false
        @loaded = false
        @loading_age = 0

        @bullet_to_return = null

        @colors.torso = 'green'
        @colors.torso_top = 'darkgreen'
        @colors.arms = @colors.pants = 'goldenrod'

    create_reader: ->
        reader = super
        reader.loading = @loading
        reader.loaded = @loaded
        reader.loading_age = @loading_age
        reader.ready_to_shoot = (@age - @loading_age > 90 and @loaded)
        return reader

    tick: ->
        super

        if @loading and @age - @loading_age > 30
            @loading = false
            @loaded = true

        if @bullet_to_return
            bullet = @bullet_to_return
            @bullet_to_return = null
            return bullet

    nock: ->
        unless @loading or @loaded
            @loading = true
            @loading_age = @age
            @walking_acceleration = 0.15

    loose: ->
        @loading = false
        @walking_acceleration = 0.3

        if @age - @loading_age > 90 and @loaded
            @loaded = false
            @bullet_to_return = new Bullet(
                @pos.plus(Vector.fromPolar(@radius + ARROW_LENGTH / 2, @dir)),
                Vector.fromPolar(ARROW_VELOCITY, @dir),
                @height,
                ARROW_LENGTH,
                90,
                'brown',
                50
            )
        @loaded = false
        return

    render_hat: (render_context, position) ->
        {ctx, canvas} = render_context

        ctx.fillStyle = 'darkgreen'
        left = position.plus(new Vector(-@radius - 2, -2))
        right = position.plus(new Vector(@radius + 2, -2))
        top = position.minus(new Vector(0, @radius * 1.5))

        ctx.beginPath()
        ctx.arc top.x, top.y, top.minus(left).magnitude(), right.minus(top).dir(), left.minus(top).dir()
        ctx.lineTo top.x, top.y
        ctx.fill()

    right_arm_vector: ->
        if @loading
            proportion = Math.min(1, (@age - @loading_age) / 30)

            return Vector.fromPolar(@height * (0.3 + 0.1 * proportion), @dir).plus(
                new Vector(0, @height / 4 * (1 - proportion))
            ).plus(
                Vector.fromPolar(@radius * proportion, @dir - Math.PI / 2)
            )
        else if @loaded
            proportion = Math.min(1, (@age - @loading_age - 30) / 60)
            return Vector.fromPolar(@height * 0.4 * (1 - proportion), @dir).plus(
                Vector.fromPolar(@radius * (1 - proportion), @dir - Math.PI / 2)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    left_arm_vector: ->
        if @loading or @loaded
            proportion = Math.min(1, (@age - @loading_age) / 30)

            return Vector.fromPolar(@height * (0.3 + 0.1 * proportion), @dir).plus(
                new Vector(0, @height / 4 * (1 - proportion))
            ).plus(
                Vector.fromPolar(@radius * proportion, @dir + Math.PI / 2)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    render_left_item: (render_context, position) ->
        {canvas, ctx} = render_context

        if @loaded
            proportion = Math.min(1, (@age - @loading_age - 30) / 60)
            top_dest = position.minus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5 * (1 + proportion), @dir))
            bottom_dest = position.plus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5 * (1 + proportion), @dir))
        else
            top_dest = position.minus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5, @dir))
            bottom_dest = position.plus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5, @dir))

        ctx.strokeStyle = BOW_COLOR
        ctx.lineWidth = BOW_THICKNESS

        # Bow itself
        ctx.beginPath()
        ctx.moveTo top_dest.x, top_dest.y
        ctx.lineTo position.x, position.y
        ctx.lineTo bottom_dest.x, bottom_dest.y
        ctx.stroke()

class Bullet
    constructor: (@pos, @velocity, @height, @length, @lifetime, @color, @damage = 5) ->
        @alive = true
        @age = 0

    create_reader: -> {@pos, @velocity, @height, @length, @lifetime, @age, @damage}

    tick: ->
        unless @alive then return

        @age += 1
        @pos.plus_inplace @velocity

        if @age > @lifetime
            @alive = false

        return

    render: (render_context) ->
        unless @alive then return

        {ctx, canvas} = render_context

        ctx.strokeStyle = @color
        ctx.lineWidth = 5

        begin = @pos.minus Vector.fromPolar @length / 2, @velocity.dir()
        end = @pos.plus Vector.fromPolar @length / 2, @velocity.dir()

        ctx.beginPath()
        ctx.moveTo begin.x, begin.y - @height
        ctx.lineTo end.x, end.y - @height
        ctx.stroke()

        ctx.strokeStyle = '#000'
        ctx.lineWidth = 5
        ctx.globalAlpha = 0.5

        ctx.beginPath()
        ctx.moveTo begin.x, begin.y
        ctx.lineTo end.x, end.y
        ctx.stroke()

        ctx.globalAlpha = 1

DAGGER_LENGTH = 10
DAGGER_COLOR = '#888'
DAGGER_LIFETIME = 10
DAGGER_VELOCITY = 2
class Rogue extends Character
    constructor: ->
        super

        @type = Rogue
        @type_string = 'rogue'

        @shooting = false
        @last_shot = 0

        @colors.arms = @colors.pants = '#440'
        @colors.torso = '#550'
        @colors.torso_top = '#220'

        @walking_acceleration = 0.5

    create_reader: ->
        reader = super
        reader.shooting = @shooting
        reader.last_shot = @last_shot
        return reader

    tick: ->
        super

        if @shooting and @age - @last_shot > 10
            @last_shot = @age
            return new Bullet(
                @pos.plus(Vector.fromPolar(@radius * 2 + DAGGER_LENGTH, @dir)),
                Vector.fromPolar(DAGGER_VELOCITY, @dir),
                @height / 2,
                DAGGER_LENGTH,
                DAGGER_LIFETIME,
                DAGGER_COLOR,
                10
            )
        return

    start_shooting: ->
        @shooting = true

    stop_shooting: ->
        @shooting = false

    right_arm_vector: ->
        if @shooting
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4 * (1 - (@age - @last_shot) / 10))
            )
        else
            super

WALL_HEIGHT = 50
class Wall
    constructor: (@pos, @width, @height) ->

    create_reader: -> {@pos, @width, @height}

    render: (render_context) ->
        {ctx, canvas, stone_asset, stone_top_asset} = render_context

        ctx.fillStyle = stone_asset
        ctx.fillRect @pos.x, @pos.y + @height - WALL_HEIGHT, @width, WALL_HEIGHT

        ctx.fillStyle = stone_top_asset
        ctx.fillRect @pos.x, @pos.y - WALL_HEIGHT, @width, @height

index_positions = [
    new Vector(50, 50)
    new Vector(50, 100)
    new Vector(100, 50)
    new Vector(100, 100)
]
instantiate_character = (template, index) ->
    switch template.class
        when 'Mage'
            return new Mage(
                50,
                10,
                index_positions[index].clone(),
                true,
                template.ai
            )
        when 'Knight'
            return new Knight(
                50,
                10,
                index_positions[index].clone(),
                true,
                template.ai
            )
        when 'Rogue'
            return new Rogue(
                50,
                10,
                index_positions[index].clone(),
                true,
                template.ai
            )
        when 'Archer'
            return new Archer(
                50,
                10,
                index_positions[index].clone(),
                true,
                template.ai
            )

BOARD_HEIGHT = 750
BOARD_WIDTH = 1500

# MAIN RUNTIME
play_game = ->
    document.getElementById('main-menu').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'

    canvas = document.getElementById 'viewport'
    ctx = canvas.getContext '2d'
    render_context = new RenderContext canvas, ctx

    canvas.width = canvas.clientWidth
    canvas.height = canvas.clientHeight

    # Draw none-sign
    none_canvas = document.getElementById('spectate-canvas')
    none_ctx = none_canvas.getContext '2d'

    none_ctx.resetTransform()
    none_ctx.clearRect 0, 0, none_canvas.width, none_canvas.height
    none_ctx.translate none_canvas.width / 2, none_canvas.height / 2
    none_ctx.rotate Math.PI / 4

    none_ctx.strokeStyle = '#F00'
    none_ctx.lineWidth = 5
    none_ctx.beginPath()
    none_ctx.arc(0, 0, 20, 0, 2 * Math.PI)
    none_ctx.moveTo(20, 0)
    none_ctx.lineTo(-20, 0)
    none_ctx.stroke()

    # Draw white flag
    quit_canvas = document.getElementById('quit-canvas')
    quit_ctx = quit_canvas.getContext '2d'

    quit_ctx.clearRect 0, 0, quit_canvas.width, quit_canvas.height
    quit_ctx.fillStyle = '#FFF'
    quit_ctx.fillRect 15, 10, 30, 20
    quit_ctx.fillStyle = 'brown'
    quit_ctx.fillRect 10, 10, 5, 50

    # Create the board
    tile_width = canvas.width / 40
    tile_height = canvas.height / 20

    characters = character_templates.map (x, i) -> instantiate_character SCRIPTS[x], i

    # Enemies
    characters = characters.concat [
        new Mage(50, 10, new Vector(BOARD_WIDTH - 50, BOARD_HEIGHT - 50), false, MAGE_AI),
        new Rogue(50, 10, new Vector(BOARD_WIDTH - 100, BOARD_HEIGHT - 50), false, ROGUE_AI)
        new Knight(50, 10, new Vector(BOARD_WIDTH - 100, BOARD_HEIGHT - 100), false, KNIGHT_AI),
        new Archer(50, 10, new Vector(BOARD_WIDTH - 50, BOARD_HEIGHT - 100), false, ARCHER_AI)
    ]

    should_continue_tick = true

    main_character = null

    bullets = []
    walls = [
        new Wall(new Vector(300, 500), 700, 30)
    ]

    # Dirt asset
    dirt_asset = ctx.createPattern(document.getElementById('dirt-asset'), 'repeat')

    # Symmetry
    new_walls = []
    for wall in walls
        new_walls.push wall
        new_walls.push new Wall(
            new Vector(
                BOARD_WIDTH - (wall.pos.x + wall.width),
                BOARD_HEIGHT - (wall.pos.y + wall.height)
            ),
            wall.width,
            wall.height
        )
    walls = new_walls

    grass_spots = [1..Math.floor(Math.random() * 20 + 10)].map ->
        new Vector(Math.random() * (BOARD_WIDTH - 100), Math.random() * (BOARD_HEIGHT - 100))
    grass_asset = document.getElementById('grass-asset')

    translate_vector = new Vector(0, 0)

    spells = characters.filter((x) -> x instanceof Mage).map((x) -> x.spell)

    for i in [1..4] then do (i) ->
        document.getElementById("char-#{i}").addEventListener 'click', ->
            if main_character
                main_character.player_controlled = false
            main_character = characters[i - 1]
            main_character.player_controlled = true

    document.getElementById('spectate').addEventListener 'click', ->
        if main_character
            main_character.player_controlled = false
        main_character = null

    document.getElementById('quit').addEventListener 'click', ->
        should_continue_tick = false
        do lose_screen

    desired_pos = new Vector(0, 0)

    canvas.addEventListener 'mousemove', (event) ->
        desired_pos = new Vector event.offsetX, event.offsetY

    keysdown = {}

    document.body.addEventListener 'keydown', (event) ->
        keysdown[event.which] = true

    document.body.addEventListener 'keyup', (event) ->
        keysdown[event.which] = false

    moving_target = null

    canvas.oncontextmenu = (e) -> e.preventDefault(); return false

    canvas.addEventListener 'mousedown', (event) ->
        if event.which is 3
            moving_target = new Vector(event.offsetX, event.offsetY).minus(translate_vector)
            event.preventDefault()
            return false

        if main_character instanceof Knight
            main_character.strike()
        else if main_character instanceof Archer
            main_character.nock()
        else if main_character instanceof Rogue
            main_character.start_shooting()
        else if main_character instanceof Mage
            main_character.cast new Vector(event.offsetX, event.offsetY).minus(translate_vector)

    document.body.addEventListener 'mouseup', (event) ->
        if main_character instanceof Archer
            result = main_character.loose()
            if result then bullets.push result
        else if main_character instanceof Rogue
            main_character.stop_shooting()
        else if main_character instanceof Mage
            main_character.cancel_casting()

    contexts = [1..4].map (i) ->
        small_canvas = document.getElementById("canvas-#{i}")
        small_ctx = small_canvas.getContext '2d'

        return new RenderContext small_canvas, small_ctx

    tick = ->
        # Move the camera
        if desired_pos.x < 50
            translate_vector.x += Math.sqrt(50 - desired_pos.x)
        if desired_pos.x > canvas.width - 50
            translate_vector.x -= Math.sqrt(desired_pos.x - (canvas.width - 50))
        if desired_pos.y < 50
            translate_vector.y += Math.sqrt(50 - desired_pos.y)
        if desired_pos.y > canvas.height - 50
            translate_vector.y -= Math.sqrt(desired_pos.y - (canvas.height - 50))

        for context, i in contexts
            context.ctx.resetTransform()
            context.ctx.clearRect 0, 0, context.canvas.width, context.canvas.height
            if characters[i].health <= 0
                context.canvas.style.opacity = '0.3'
            else
                context.canvas.style.opacity = '1'
            context.ctx.translate -characters[i].pos.x + context.canvas.width / 2, -characters[i].pos.y + characters[i].height + 35

            characters[i].render context

        # Edges
        translate_vector.x = -Math.max -50, Math.min BOARD_WIDTH + 50 - canvas.width, -translate_vector.x
        translate_vector.y = -Math.max -50, Math.min BOARD_HEIGHT + 50 - canvas.height, -translate_vector.y

        # Check win condition
        if characters.filter((x) -> x.health > 0 and x.allegiance).length == 0
            characters.forEach (x) -> x.ai_runner.terminate()
            return lose_screen()
        else if characters.filter((x) -> x.health > 0 and not x.allegiance).length == 0
            characters.forEach (x) -> x.ai_runner.terminate()
            return win_screen()
        else if should_continue_tick
            setTimeout tick, 1000 / FRAME_RATE

        ctx.resetTransform()

        ctx.clearRect 0, 0, canvas.width, canvas.height

        if main_character
            desired_dir = desired_pos.minus(translate_vector)
                .minus(main_character.pos.minus(new Vector(0, main_character.height))).dir()

            normalized_delta = wrap_angle(desired_dir - main_character.dir)
            main_character.angular_dir = 10 * normalized_delta / Math.PI

            prototype_vector = new Vector(0, 0)
            main_character.moving = false

            if keysdown[key_codes.w]
                main_character.moving = true
                prototype_vector.y -= 1
            if keysdown[key_codes.s]
                main_character.moving = true
                prototype_vector.y += 1
            if keysdown[key_codes.a]
                main_character.moving = true
                prototype_vector.x -= 1
            if keysdown[key_codes.d]
                main_character.moving = true
                prototype_vector.x += 1

            if main_character.moving
                main_character.movement_dir = prototype_vector.dir()

        ctx.translate(translate_vector.x, translate_vector.y)

        # Draw the board
        ctx.fillStyle = dirt_asset #'#faa460'
        ctx.fillRect 0, 0, BOARD_WIDTH, BOARD_HEIGHT

        for spot in grass_spots
            ctx.drawImage grass_asset, spot.x, spot.y

        for spell in spells
            spell.tick()
            spell.render render_context

        for character in characters when character.health > 0
            # Detect spell intersection.
            # Spells do damage every frame.
            for spell in spells
                if spell.alive and spell.burning and character.pos.minus(spell.pos).magnitude() < SPELL_RADIUS
                    character.damage 1

            # Detect character intersection for knights
            if character.striking_sideways
                for target in characters when target isnt character and character.health > 0
                    if character.pos.minus(target.pos).magnitude() < character.radius * 2.5 + target.radius and
                            Math.abs(wrap_angle(target.pos.minus(character.pos).dir() - character.dir)) < Math.PI / 2
                        target.damage 3

            result = character.tick {characters, walls, spells, bullets}

            # Detect edge intersection
            if character.pos.x < character.hitbox_radius then character.pos.x = character.hitbox_radius
            if character.pos.x > BOARD_WIDTH - character.hitbox_radius then character.pos.x = BOARD_WIDTH - character.hitbox_radius

            if character.pos.y < character.hitbox_radius then character.pos.y = character.hitbox_radius
            if character.pos.y > BOARD_HEIGHT - character.hitbox_radius then character.pos.y = BOARD_HEIGHT - character.hitbox_radius

            # Detect wall intersection
            for wall in walls
                # Running into a wall; we have a problem
                if wall.pos.x < character.pos.x + character.hitbox_radius and
                        character.pos.x - character.hitbox_radius < wall.pos.x + wall.width and
                        wall.pos.y < character.pos.y + character.hitbox_radius and
                        character.pos.y - character.hitbox_radius < wall.pos.y + wall.height

                    # Pop us to one side of the rectangle
                    bottom_intersect = new Vector(
                        character.pos.x,
                        wall.pos.y + wall.height + character.hitbox_radius
                    )
                    top_intersect = new Vector(
                        character.pos.x,
                        wall.pos.y - character.hitbox_radius
                    )
                    right_intersect = new Vector(
                        wall.pos.x + wall.width + character.hitbox_radius,
                        character.pos.y
                    )
                    left_intersect = new Vector(
                        wall.pos.x - character.hitbox_radius,
                        character.pos.y
                    )

                    # Find the closest one and send us there.
                    distances = [bottom_intersect, top_intersect, right_intersect, left_intersect].map (p) ->
                        p.minus(character.pos).magnitude()

                    min_dist = Math.min.apply window, distances

                    if min_dist is distances[0]
                        character.pos.copy bottom_intersect
                        continue
                    if min_dist is distances[1]
                        character.pos.copy top_intersect
                        continue
                    if min_dist is distances[2]
                        character.pos.copy right_intersect
                        continue
                    if min_dist is distances[3]
                        character.pos.copy left_intersect
                        continue

            if result
                bullets.push result

        entities = characters.concat(walls).sort (a, b) -> if a.pos.y > b.pos.y then return 1 else return -1
        for entity in entities when (not entity.health?) or entity.health > 0
            entity.render render_context

        new_bullets = []
        for bullet in bullets
            bullet.tick()
            bullet.render render_context

            # Detect character intersection
            for character in characters when character.health > 0
                if bullet.pos.minus(character.pos).magnitude() < character.hitbox_radius
                    character.damage bullet.damage
                    bullet.alive = false
                    continue

            for wall in walls
                if wall.pos.x < bullet.pos.x < wall.pos.x + wall.width and wall.pos.y < bullet.pos.y < wall.pos.y + wall.height
                    bullet.alive = false
                    continue

            if bullet.alive
                new_bullets.push bullet

        bullets = new_bullets

    tick()

create_ai_from_template = (program) ->
    return """
    var me;

    function wrap_angle(ang) {
        return (((ang + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI)) - Math.PI
    }

    function Vector(x, y) {
        this.x = x;
        this.y = y;
    }

    Vector.prototype.plus = function(o) {
        return new Vector(this.x + o.x, this.y + o.y);
    };

    Vector.prototype.minus = function(o) {
        return new Vector(this.x - o.x, this.y - o.y);
    };

    Vector.prototype.times = function(s) {
        return new Vector(this.x * s, this.y * s);
    };

    Vector.prototype.divided_by = function(s) {
        return new Vector(this.x / s, this.y / s);
    };

    Vector.prototype.magnitude = function() {
        return Math.sqrt(this.x * this.x + this.y * this.y);
    };

    Vector.prototype.dir_to = function(other) {
        return other.minus(this).dir();
    }

    Vector.prototype.distance = function(other) {
        return this.minus(other).magnitude();
    }

    Vector.prototype.unit = function() {
      return this.divided_by(this.magnitude());
    };

    Vector.prototype.dir = function() {
      return Math.atan2(this.y, this.x);
    };

    function move(dir) {
        postMessage({type: 'move', dir: dir})
    }
    function move_toward(pos) {
        postMessage({type: 'move', dir: pos.minus(me.pos).dir()});
    }
    function turn(dir) {
        postMessage({type: 'turn', dir: dir})
    }
    function turn_to(dir) {
        normalized_delta = wrap_angle(dir - me.dir);
        turn(10 * normalized_delta / Math.PI);
    }
    function turn_toward(pos) {
        var desired_dir = pos.minus(me.pos).dir();
        turn_to(desired_dir)
    }
    function strike() {
        postMessage({type: 'strike'})
    }
    function start_shooting() {
        postMessage({type: 'start_shooting'})
    }
    function stop_shooting() {
        postMessage({type: 'stop_shooting'})
    }
    function nock() {
        postMessage({type: 'nock'})
    }
    function loose() {
        postMessage({type: 'loose'})
    }
    function cast(target) {
        postMessage({type: 'cast', target: target})
    }
    function cancel_casting() {
        postMessage({type: 'cancel_casting'})
    }

    function unpack(obj) {
        if (obj.pos) {
            obj.pos = new Vector(obj.pos.x, obj.pos.y)
        }
        if (obj.velocity) {
            obj.velocity = new Vector(obj.velocity.x, obj.velocity.y)
        }
        return obj;
    }

    onmessage = function(e) {
        var info = e.data;
        var characters = info.characters.map(unpack),
            bullets = info.bullets.map(unpack),
            spells = info.spells.map(unpack),
            walls = info.walls.map(unpack);

        me = unpack(info.main_character);

        (function() {
        #{program}
        }());

        postMessage({type: 'ready'})
    }
"""

DUMBO = '''
    if (Math.random() < 1 / 60) {
        direction = Math.random() * 2 * Math.PI;
        move(direction);
    }
'''

ROGUE_AI = '''
    /*
     * A basic Rogue AI that chases the nearest enemy.
     *
     * Improve on this to win more games!
     */

    // Always be shooting knives
    start_shooting();

    // Get players on the board NOT on our team
    var enemies = characters.filter(function(x) { return !x.allegiance });

    // Sort them by distance to us
    enemies.sort(function(a, b) {
        return a.pos.distance(me.pos) - b.pos.distance(me.pos);
    });

    // Get nearest enemy
    var target = enemies[0];

    // Turn towards it
    turn_toward(target.pos);

    // If we're farther than stabbing range,
    // move towards it.
    if (me.pos.distance(target.pos) > 40) {
        move_toward(target.pos);
    }'''

KNIGHT_AI = '''
    /*
     * A basic Knight AI that chases the nearest enemy.
     *
     * Improve on this to win more games!
     */

    // Get players on the board NOT on our team
    var enemies = characters.filter(function(x) { return !x.allegiance });

    // Sort them by distance to us
    enemies.sort(function(a, b) {
        return a.pos.distance(me.pos) - b.pos.distance(me.pos);
    });

    // Get nearest enemy
    var target = enemies[0];

    // Turn towards it and move towards it
    turn_toward(target.pos);
    move_toward(target.pos);

    // If we're in range, strike
    if (me.pos.distance(target.pos) <= 40) {
        strike();
    }'''

MAGE_AI = '''
    /*
     * A basic Mage AI that flees and casts spells at the nearest enemy.
     *
     * Improve on this to win more games!
     */

    // Get players on the board NOT on our team
    var enemies = characters.filter(function(x) { return !x.allegiance });

    // Sort them by distance to us
    enemies.sort(function(a, b) {
        return a.pos.distance(me.pos) - b.pos.distance(me.pos);
    });

    // Get nearest enemy
    var target = enemies[0];

    // If the enemy is too close, run away!
    if (me.pos.distance(target.pos) < 200) {
        cancel_casting();
        move(target.pos.dir_to(me.pos));
    }

    // Otherwise, cast a spell at them
    else {
        cast(target.pos);
    }'''

ARCHER_AI = '''
    /*
     * A basic Archer AI that flees and shoots arrows at the nearest enemy.
     *
     * Improve on this to win more games!
     */

    // Get players on the board NOT on our team
    var enemies = characters.filter(function(x) { return !x.allegiance });

    // Sort them by distance to us
    enemies.sort(function(a, b) {
        return a.pos.distance(me.pos) - b.pos.distance(me.pos);
    });

    // Get nearest enemy
    var target = enemies[0];

    // Turn to them
    turn_toward(target.pos);

    // If the enemy is too close, run away!
    if (me.pos.distance(target.pos) < 200) {
        loose();
        move(target.pos.dir_to(me.pos));
    }

    // If we have an arrow ready, shoot it at them.
    else if (me.ready_to_shoot) {
        loose();
    }

    // Otherwise, nock one.
    else {
        nock();
    }'''

DEFAULT_COLORS = {
    pants: 'black'
    torso: 'chocolate'
    torso_top: 'brown'
    arms: 'black'
    head: 'tan'
}

NECK_HEIGHT = 10
FRICTION = 0.8
ANGULAR_FRICTION = 0.5
TORSO_PROPORTION = 0.4

key_codes = {
    w: 87,
    s: 83,
    a: 65,
    d: 68
}

FRAME_RATE = 60 #100
WALKING_PERIOD = 50
WALKING_RATIO = 0.7
SHIELD_RATIO = 0.7

class Script
    constructor: (@name, @class, @ai) ->

SCRIPTS = [
    new Script('Basic', 'Mage', MAGE_AI),
    new Script('Basic', 'Knight', KNIGHT_AI),
    new Script('Basic', 'Archer', ARCHER_AI),
    new Script('Basic', 'Rogue', ROGUE_AI)
]

character_templates = [0, 0, 0, 0]

'''
ARCHETYPES = {
    'Mage': new Mage(50, 10, new Vector(25, 85), true)
    'Archer': new Archer(50, 10, new Vector(25, 85), true)
    'Knight': new Knight(50, 10, new Vector(25, 85), true)
    'Rogue': new Rogue(50, 10, new Vector(25, 85), true)
}
'''

win_screen = ->
    document.getElementById('win-screen').style.display = 'block'

lose_screen = ->
    document.getElementById('lose-screen').style.display = 'block'

main_menu = ->
    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'block'

# Edit screen
ace_editor = ace.edit document.getElementById 'edit-editor'
ace_editor.session.setMode 'ace/mode/javascript'
ace_editor.setValue SCRIPTS[character_templates[0]].ai, -1

currently_editing = 0

prototype_list = document.getElementById('prototype-list')

script_elements = []
selected_element = null

update_prototype_list = ->
    for script, i in SCRIPTS then do (script, i) ->
        element = document.createElement 'div'
        element.className = 'script-' + script.class
        element.innerText = script.name

        wrapper = document.createElement 'div'
        wrapper.className = 'button'
        wrapper.appendChild element

        script_elements.push wrapper

        prototype_list.appendChild wrapper

        element.addEventListener 'click', ->
            selected_element?.className = selected_element.className.split(' ')[0]
            wrapper.className += ' selected'
            selected_element = wrapper
            character_templates[currently_editing] = i

            ace_editor.setValue SCRIPTS[i].ai, -1
            do rerender_tabs

do update_prototype_list

ace_editor.on 'change', ->
    SCRIPTS[character_templates[currently_editing]].ai = ace_editor.getValue()

edit_screen = ->
    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'block'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'none'

    do rerender_tabs

IMAGE_URLS = {
    'Mage': 'mage-prototype.png'
    'Knight': 'knight-prototype.png'
    'Rogue': 'rogue-prototype.png'
    'Archer': 'archer-prototype.png'
}

rerender_tabs = ->
    for template, i in character_templates
        document.getElementById("edit-tab-#{i + 1}").style.backgroundImage = "url(\"#{IMAGE_URLS[SCRIPTS[template].class]}\")"

edit_tab_elements = []
selected_tab_element = null
for i in [0...4] then do (i) ->
    edit_tab_elements[i] = document.getElementById("edit-tab-#{i + 1}")
    edit_tab_elements[i].addEventListener 'click', (x) ->
        selected_tab_element.className = selected_tab_element.className.split(' ')[0]
        selected_tab_element = edit_tab_elements[i]
        selected_tab_element.className += ' selected-tab'

        currently_editing = i

        element = script_elements[character_templates[i]]
        selected_element?.className = selected_element.className.split(' ')[0]
        element.className += ' selected'
        selected_element = element

        ace_editor.setValue SCRIPTS[character_templates[i]].ai, -1

element = script_elements[character_templates[0]]
selected_element?.className = selected_element.className.split(' ')[0]
selected_element = element
element.className += ' selected'

selected_tab_element = edit_tab_elements[0]
console.log 'setting selected_tab_element', selected_tab_element

document.getElementById('main-menu-win').addEventListener 'click', main_menu
document.getElementById('main-menu-lose').addEventListener 'click', main_menu
document.getElementById('quick-match').addEventListener 'click', edit_screen
document.getElementById('edit-team').addEventListener 'click', edit_screen
document.getElementById('begin').addEventListener 'click', play_game
document.getElementById('back').addEventListener 'click', main_menu

main_menu()
