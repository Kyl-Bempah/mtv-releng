from pydantic import BaseModel


class Store:
    instance = None

    def __new__(cls):
        if cls.instance is None:
            cls.instance = super().__new__(cls)
        return cls.instance

    def write(self, key: str, value: BaseModel):
        value.json()
