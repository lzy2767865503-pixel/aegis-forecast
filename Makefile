.PHONY: setup run test verify demo

setup:
	./scripts/setup.sh

run:
	./scripts/run.sh

test:
	PYTHONPATH=backend:. ./.venv/bin/python -m unittest discover -s tests -v

verify:
	./scripts/verify.sh

demo:
	PYTHONPATH=backend:. ./.venv/bin/python scripts/generate_demo_data.py
