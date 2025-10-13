.PHONY: render up down ps logs clean

render:
	@python3 scripts/gen-compose-override.py

up: render
	docker compose -f docker-compose.yml -f compose.bricks.override.yml up -d

down:
	docker compose -f docker-compose.yml -f compose.bricks.override.yml down

ps:
	docker compose -f docker-compose.yml -f compose.bricks.override.yml ps

logs:
	docker compose -f docker-compose.yml -f compose.bricks.override.yml logs -f

clean:
	rm -f compose.bricks.override.yml
