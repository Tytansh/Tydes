from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Literal

from pydantic import BaseModel, EmailStr, Field


class User(BaseModel):
    id: str
    email: EmailStr
    display_name: str
    home_region: str
    locale: str
    premium: bool = False
    free_live_spot_id: str | None = None
    ads_enabled: bool = True
    favorite_spot_ids: list[str] = Field(default_factory=list)


class Session(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    user: User


class Spot(BaseModel):
    id: str
    name: str
    country: str
    region: str
    area: str
    latitude: float
    longitude: float
    difficulty: Literal["beginner", "intermediate", "advanced"]
    best_months: list[str]
    wave_height_m: float
    water_temp_c: float
    image_url: str
    summary: str


class ForecastEntry(BaseModel):
    id: str
    spot_id: str
    day: date
    wave_height_m: float | None = None
    wave_height_min_m: float | None = None
    wave_height_max_m: float | None = None
    period_s: int | None = None
    wind_kts: float | None = None
    wind_kts_min: float | None = None
    wind_kts_max: float | None = None
    quality: Literal["poor", "fair", "good", "epic"]
    swell_wave_height_m: float | None = None
    wind_wave_height_m: float | None = None
    sea_surface_temperature_c: float | None = None
    source: str = "seed"
    confidence: Literal["live", "estimated"] = "estimated"
    confidence_note: str | None = None


class TideEvent(BaseModel):
    type: Literal["high", "low"]
    time: datetime
    local_time: str
    local_date: date
    height_m: float | None = None


class TideForecast(BaseModel):
    spot_id: str
    available: bool
    station_name: str | None = None
    station_distance_km: float | None = None
    source: str = "unavailable"
    events: list[TideEvent] = Field(default_factory=list)
    note: str | None = None


class Trip(BaseModel):
    id: str
    user_id: str
    title: str
    destination: str
    start_date: date
    end_date: date
    travelers: int = 1
    notes: str = ""
    budget_usd: int = 0


class Alert(BaseModel):
    id: str
    user_id: str
    spot_id: str
    min_wave_height_m: float
    max_wind_kts: int
    enabled: bool = True
    next_check_at: datetime


class FriendProfile(BaseModel):
    id: str
    display_name: str
    home_region: str
    avatar_emoji: str
    vibe: str


class SocialMediaAttachment(BaseModel):
    id: str
    media_type: Literal["photo", "video"] = "photo"
    url: str
    thumbnail_url: str
    width: int | None = None
    height: int | None = None
    alt_text: str | None = None


class SocialPost(BaseModel):
    id: str
    user_id: str
    author_name: str
    spot_id: str | None = None
    post_type: Literal["looking_for_buddy", "surf_plan", "general"]
    visibility: Literal["public", "friends"] = "public"
    body: str
    media: list[SocialMediaAttachment] = Field(default_factory=list)
    meetup_date: date | None = None
    created_at: datetime


class BillingPlan(BaseModel):
    id: str
    name: str
    price_usd_monthly: float
    features: list[str]


class AdCard(BaseModel):
    id: str
    title: str
    partner: str
    cta: str
    image_url: str
    placement: Literal["home_feed", "spot_detail", "trip_planner"]


class Dashboard(BaseModel):
    featured_spot: Spot
    top_forecast: ForecastEntry
    upcoming_trip: Trip | None
    alerts_enabled: int


def build_seed() -> dict[str, list[BaseModel] | User]:
    today = datetime.now(timezone.utc).date()
    user = User(
        id="usr_demo",
        email="demo@surftravel.app",
        display_name="Maya Surfer",
        home_region="Bali",
        locale="en",
        premium=False,
        free_live_spot_id="spot_uluwatu_peak",
        ads_enabled=True,
    )
    spots = [
        Spot(
            id="spot_uluwatu_peak",
            name="Uluwatu Peak",
            country="Indonesia",
            region="Bali",
            area="Uluwatu",
            latitude=-8.8184,
            longitude=115.0889,
            difficulty="advanced",
            best_months=["Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.9,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Powerful reef break with multiple sections and sunrise patrol magic.",
        ),
        Spot(
            id="spot_padang_padang",
            name="Padang Padang",
            country="Indonesia",
            region="Bali",
            area="Uluwatu",
            latitude=-8.8057,
            longitude=115.1018,
            difficulty="advanced",
            best_months=["Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.6,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1473116763249-2faaef81ccda",
            summary="Barreling reef setup with a compact takeoff and classic dry-season energy.",
        ),
        Spot(
            id="spot_balangan",
            name="Balangan",
            country="Indonesia",
            region="Bali",
            area="Uluwatu",
            latitude=-8.7907,
            longitude=115.1212,
            difficulty="intermediate",
            best_months=["Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.5,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Long playful left with easier paddling than the heaviest Bukit reefs.",
        ),
        Spot(
            id="spot_echo_beach",
            name="Echo Beach",
            country="Indonesia",
            region="Bali",
            area="Canggu",
            latitude=-8.6481,
            longitude=115.1385,
            difficulty="intermediate",
            best_months=["Apr", "May", "Jun", "Sep"],
            wave_height_m=1.4,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="A flexible cluster of beach and reef breaks with cafes nearby.",
        ),
        Spot(
            id="spot_batu_bolong",
            name="Batu Bolong",
            country="Indonesia",
            region="Bali",
            area="Canggu",
            latitude=-8.6618,
            longitude=115.1303,
            difficulty="beginner",
            best_months=["Apr", "May", "Jun", "Sep"],
            wave_height_m=1.0,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Friendly longboard wave with mellow takeoffs and easy post-surf hangs.",
        ),
        Spot(
            id="spot_berawa",
            name="Berawa",
            country="Indonesia",
            region="Bali",
            area="Canggu",
            latitude=-8.6591,
            longitude=115.1344,
            difficulty="intermediate",
            best_months=["Apr", "May", "Jun", "Sep"],
            wave_height_m=1.3,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Punchier beach break peaks with plenty of movement through the tides.",
        ),
        Spot(
            id="spot_siargao",
            name="Cloud 9",
            country="Philippines",
            region="Siargao",
            area="General Luna",
            latitude=9.8136,
            longitude=126.1661,
            difficulty="advanced",
            best_months=["Sep", "Oct", "Nov"],
            wave_height_m=1.7,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Fast reef setup with punchy walls and a world-class surf trip vibe.",
        ),
        Spot(
            id="spot_jacking_horse",
            name="Jacking Horse",
            country="Philippines",
            region="Siargao",
            area="General Luna",
            latitude=9.8084,
            longitude=126.1654,
            difficulty="intermediate",
            best_months=["Sep", "Oct", "Nov"],
            wave_height_m=1.2,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="More approachable Siargao reef option with playful walls on medium swells.",
        ),
        Spot(
            id="spot_quicksilver",
            name="Quicksilver",
            country="Philippines",
            region="Siargao",
            area="General Luna",
            latitude=9.8008,
            longitude=126.1587,
            difficulty="advanced",
            best_months=["Sep", "Oct", "Nov"],
            wave_height_m=1.5,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="Fast playful right that lights up on cleaner swells just down the road from Cloud 9.",
        ),
        Spot(
            id="spot_pacifico",
            name="Pacifico",
            country="Philippines",
            region="Siargao",
            area="Pacifico",
            latitude=9.9875,
            longitude=126.0864,
            difficulty="intermediate",
            best_months=["Oct", "Nov", "Dec"],
            wave_height_m=1.4,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Scenic reef and beach setup on Siargao's quieter north side with more room to move.",
        ),
        Spot(
            id="spot_monaliza",
            name="Monaliza",
            country="Philippines",
            region="Siargao",
            area="Pilar",
            latitude=9.8628,
            longitude=126.1101,
            difficulty="intermediate",
            best_months=["Oct", "Nov", "Dec"],
            wave_height_m=1.3,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Long left with playful sections that makes a strong alternative when Cloud 9 is crowded.",
        ),
        Spot(
            id="spot_urmizno",
            name="Urmizno",
            country="Philippines",
            region="La Union",
            area="San Juan",
            latitude=16.6767,
            longitude=120.3312,
            difficulty="intermediate",
            best_months=["Oct", "Nov", "Dec", "Jan"],
            wave_height_m=1.2,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="The heart of the La Union scene with rippable peaks, surf schools, and easy access.",
        ),
        Spot(
            id="spot_sabang_baler",
            name="Sabang Beach",
            country="Philippines",
            region="Baler",
            area="Sabang",
            latitude=15.7606,
            longitude=121.5605,
            difficulty="beginner",
            best_months=["Oct", "Nov", "Dec", "Jan"],
            wave_height_m=1.1,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Beginner-friendly beach break with lots of local history and easy day-long sessions.",
        ),
        Spot(
            id="spot_crystal_beach",
            name="Crystal Beach",
            country="Philippines",
            region="Zambales",
            area="San Narciso",
            latitude=15.0369,
            longitude=120.0806,
            difficulty="beginner",
            best_months=["Oct", "Nov", "Dec", "Jan"],
            wave_height_m=1.0,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Easy-access beach break weekend zone for Manila surfers and newer riders.",
        ),
        Spot(
            id="spot_stimpy",
            name="Stimpy's",
            country="Indonesia",
            region="Mentawai",
            area="Playgrounds",
            latitude=-2.1683,
            longitude=99.7836,
            difficulty="advanced",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.8,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Mechanical left reef in the Mentawais with boat-trip dream energy.",
        ),
        Spot(
            id="spot_lances_right",
            name="Lance's Right",
            country="Indonesia",
            region="Mentawai",
            area="Playgrounds",
            latitude=-2.2974,
            longitude=99.9729,
            difficulty="advanced",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.9,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="Long wrapping right with one of the most photogenic walls in Indonesia.",
        ),
        Spot(
            id="spot_desert_point",
            name="Desert Point",
            country="Indonesia",
            region="Lombok",
            area="Sekotong",
            latitude=-8.7498,
            longitude=115.9255,
            difficulty="advanced",
            best_months=["May", "Jun", "Jul", "Aug"],
            wave_height_m=2.0,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Legendary freight-train left that turns on when the swell and wind line up.",
        ),
        Spot(
            id="spot_lakey_peak",
            name="Lakey Peak",
            country="Indonesia",
            region="Sumbawa",
            area="Hu'u",
            latitude=-8.4893,
            longitude=118.9973,
            difficulty="intermediate",
            best_months=["Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.6,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Rippable peak with rights and lefts, perfect for a strike mission in Sumbawa.",
        ),
        Spot(
            id="spot_nias",
            name="Lagundri Bay",
            country="Indonesia",
            region="Nias",
            area="Sorake",
            latitude=0.5715,
            longitude=97.8342,
            difficulty="advanced",
            best_months=["Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.9,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1473116763249-2faaef81ccda",
            summary="Machine-like right-hander with a deep surf heritage and serious power.",
        ),
        Spot(
            id="spot_da_nang",
            name="My Khe Beach",
            country="Vietnam",
            region="Da Nang",
            area="Da Nang",
            latitude=16.0741,
            longitude=108.2468,
            difficulty="beginner",
            best_months=["Sep", "Oct", "Nov", "Dec"],
            wave_height_m=1.1,
            water_temp_c=26.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Accessible city beach with a growing local scene and easy first sessions.",
        ),
        Spot(
            id="spot_non_nuoc",
            name="Non Nuoc Beach",
            country="Vietnam",
            region="Da Nang",
            area="Ngu Hanh Son",
            latitude=15.9976,
            longitude=108.2669,
            difficulty="beginner",
            best_months=["Sep", "Oct", "Nov", "Dec"],
            wave_height_m=1.0,
            water_temp_c=26.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="More relaxed southern Da Nang beach stretch with roomier peaks and mellow travel flow.",
        ),
        Spot(
            id="spot_mui_ne",
            name="Suoi Nuoc",
            country="Vietnam",
            region="Mui Ne",
            area="Mui Ne",
            latitude=10.9827,
            longitude=108.3284,
            difficulty="intermediate",
            best_months=["Nov", "Dec", "Jan", "Feb"],
            wave_height_m=1.2,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1473116763249-2faaef81ccda",
            summary="Windy open-ocean stretch with more size than central-town beaches during the season.",
        ),
        Spot(
            id="spot_nha_trang",
            name="Bai Dai",
            country="Vietnam",
            region="Nha Trang",
            area="Cam Lam",
            latitude=12.0624,
            longitude=109.1959,
            difficulty="beginner",
            best_months=["Oct", "Nov", "Dec"],
            wave_height_m=1.0,
            water_temp_c=27.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Long sandy stretch south of Nha Trang with easy beach-break entries and space to spread out.",
        ),
        Spot(
            id="spot_vung_tau",
            name="Back Beach",
            country="Vietnam",
            region="Vung Tau",
            area="Vung Tau",
            latitude=10.3354,
            longitude=107.0907,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=0.9,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Popular city beach with smaller summer surf and easy access from Ho Chi Minh City.",
        ),
        Spot(
            id="spot_kata",
            name="Kata Beach",
            country="Thailand",
            region="Phuket",
            area="Kata",
            latitude=7.8215,
            longitude=98.2972,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.0,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Fun monsoon-season beach break with mellow travel logistics and warm water.",
        ),
        Spot(
            id="spot_kalim",
            name="Kalim Beach",
            country="Thailand",
            region="Phuket",
            area="Patong",
            latitude=7.9135,
            longitude=98.2852,
            difficulty="intermediate",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.1,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Rocky reef-and-beach mix with punchier sections than the friendlier Phuket learner waves.",
        ),
        Spot(
            id="spot_nai_harn",
            name="Nai Harn",
            country="Thailand",
            region="Phuket",
            area="Rawai",
            latitude=7.7802,
            longitude=98.3047,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=0.9,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Friendly shoulder-season Phuket option with smaller surf and an easy beach vibe.",
        ),
        Spot(
            id="spot_memories",
            name="Memories Beach",
            country="Thailand",
            region="Khao Lak",
            area="Takua Pa",
            latitude=8.8778,
            longitude=98.2148,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.0,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="One of Thailand's most welcoming surf beaches with mellow peaks and a strong beginner scene.",
        ),
        Spot(
            id="spot_koh_phayam",
            name="Aow Yai",
            country="Thailand",
            region="Koh Phayam",
            area="Ranong",
            latitude=9.7304,
            longitude=98.4102,
            difficulty="intermediate",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.2,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Remote Andaman island setup with fun seasonal surf and a low-key travel feel.",
        ),
        Spot(
            id="spot_cherating",
            name="Cherating",
            country="Malaysia",
            region="Pahang",
            area="Cherating",
            latitude=4.1232,
            longitude=103.3891,
            difficulty="beginner",
            best_months=["Nov", "Dec", "Jan", "Feb"],
            wave_height_m=1.1,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Malaysia's best-known surf zone with easy beach-break learning conditions during the monsoon.",
        ),
        Spot(
            id="spot_batu_burok",
            name="Batu Burok",
            country="Malaysia",
            region="Terengganu",
            area="Kuala Terengganu",
            latitude=5.3078,
            longitude=103.1548,
            difficulty="beginner",
            best_months=["Nov", "Dec", "Jan"],
            wave_height_m=1.0,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Fun northeast monsoon beach break that helps round out Peninsular Malaysia surf trips.",
        ),
        Spot(
            id="spot_kudat",
            name="Kudat Left",
            country="Malaysia",
            region="Sabah",
            area="Kudat",
            latitude=6.8944,
            longitude=116.8354,
            difficulty="intermediate",
            best_months=["Dec", "Jan", "Feb"],
            wave_height_m=1.3,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Remote Borneo corner with more adventurous surf-travel appeal and less crowded lineups.",
        ),
        Spot(
            id="spot_ngwe_saung",
            name="Ngwe Saung Beach",
            country="Myanmar",
            region="Ayeyarwady",
            area="Ngwe Saung",
            latitude=16.9642,
            longitude=94.4362,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.0,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Undeveloped beach-break zone with frontier travel energy and soft seasonal surf.",
        ),
        Spot(
            id="spot_nabule",
            name="Nabule Beach",
            country="Myanmar",
            region="Tanintharyi",
            area="Dawei",
            latitude=14.0955,
            longitude=98.1956,
            difficulty="intermediate",
            best_months=["May", "Jun", "Jul", "Aug"],
            wave_height_m=1.2,
            water_temp_c=29.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Remote southern Myanmar coastline with more open-ocean exposure than the country's better-known beaches.",
        ),
        Spot(
            id="spot_areia_branca",
            name="Areia Branca",
            country="Timor-Leste",
            region="Dili",
            area="Dili",
            latitude=-8.5447,
            longitude=125.5597,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=0.9,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Capital-adjacent beach option that helps introduce Timor-Leste into the surf-travel map.",
        ),
        Spot(
            id="spot_jaco",
            name="Jaco Island",
            country="Timor-Leste",
            region="Lautem",
            area="Tutuala",
            latitude=-8.4205,
            longitude=127.3254,
            difficulty="intermediate",
            best_months=["May", "Jun", "Jul", "Aug", "Sep"],
            wave_height_m=1.3,
            water_temp_c=28.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="Far-east Timor adventure zone with empty-lineup fantasy energy and serious travel-story value.",
        ),
        Spot(
            id="spot_scarborough",
            name="Scarborough Beach",
            country="Australia",
            region="Western Australia",
            area="Perth",
            latitude=-31.8945,
            longitude=115.7512,
            difficulty="beginner",
            best_months=["May", "Jun", "Jul", "Aug"],
            wave_height_m=1.1,
            water_temp_c=21.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Perth city beach with accessible peaks and a great local content-and-lifestyle angle.",
        ),
        Spot(
            id="spot_trigg",
            name="Trigg Point",
            country="Australia",
            region="Western Australia",
            area="Perth",
            latitude=-31.8725,
            longitude=115.7573,
            difficulty="intermediate",
            best_months=["May", "Jun", "Jul", "Aug"],
            wave_height_m=1.4,
            water_temp_c=21.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Perth's most recognizable surf zone with more punch and a strong local crowd when it is on.",
        ),
        Spot(
            id="spot_yallingup",
            name="Yallingup",
            country="Australia",
            region="Western Australia",
            area="Margaret River",
            latitude=-33.6466,
            longitude=115.0187,
            difficulty="intermediate",
            best_months=["Mar", "Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.8,
            water_temp_c=20.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="Iconic WA reef-and-point setup with a polished surf-travel feel and year-round credibility.",
        ),
        Spot(
            id="spot_surfers_point",
            name="Surfers Point",
            country="Australia",
            region="Western Australia",
            area="Margaret River",
            latitude=-33.9534,
            longitude=114.9932,
            difficulty="advanced",
            best_months=["Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=2.2,
            water_temp_c=20.0,
            image_url="https://images.unsplash.com/photo-1473116763249-2faaef81ccda",
            summary="Heavy open-ocean WA stage with serious size, power, and global contest recognition.",
        ),
        Spot(
            id="spot_snapper",
            name="Snapper Rocks",
            country="Australia",
            region="Queensland",
            area="Gold Coast",
            latitude=-28.1649,
            longitude=153.5482,
            difficulty="advanced",
            best_months=["Feb", "Mar", "Apr", "May", "Jun"],
            wave_height_m=1.7,
            water_temp_c=24.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="World-famous superbank right with long walls and serious travel-destination gravity.",
        ),
        Spot(
            id="spot_burleigh",
            name="Burleigh Heads",
            country="Australia",
            region="Queensland",
            area="Gold Coast",
            latitude=-28.0918,
            longitude=153.4544,
            difficulty="intermediate",
            best_months=["Mar", "Apr", "May", "Jun"],
            wave_height_m=1.5,
            water_temp_c=24.0,
            image_url="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee",
            summary="Crowded but beautiful point setup with one of the best hill-and-lineup views in Australia.",
        ),
        Spot(
            id="spot_noosa",
            name="First Point",
            country="Australia",
            region="Queensland",
            area="Noosa",
            latitude=-26.3847,
            longitude=153.0907,
            difficulty="beginner",
            best_months=["Mar", "Apr", "May", "Jun"],
            wave_height_m=1.2,
            water_temp_c=24.0,
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            summary="Classic longboard-friendly point with smooth walls and huge surf-culture appeal.",
        ),
        Spot(
            id="spot_bells",
            name="Bells Beach",
            country="Australia",
            region="Victoria",
            area="Torquay",
            latitude=-38.3712,
            longitude=144.2830,
            difficulty="advanced",
            best_months=["Mar", "Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.9,
            water_temp_c=17.0,
            image_url="https://images.unsplash.com/photo-1519046904884-53103b34b206",
            summary="Cold-water icon with long walls, big surf heritage, and a serious performance identity.",
        ),
        Spot(
            id="spot_bondi",
            name="Bondi",
            country="Australia",
            region="New South Wales",
            area="Sydney",
            latitude=-33.8915,
            longitude=151.2767,
            difficulty="beginner",
            best_months=["Mar", "Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.0,
            water_temp_c=21.0,
            image_url="https://images.unsplash.com/photo-1493558103817-58b2924bce98",
            summary="Famous Sydney beach with accessible peaks, heavy crowds, and huge content potential.",
        ),
        Spot(
            id="spot_manly",
            name="Manly",
            country="Australia",
            region="New South Wales",
            area="Sydney",
            latitude=-33.7969,
            longitude=151.2870,
            difficulty="intermediate",
            best_months=["Mar", "Apr", "May", "Jun", "Jul", "Aug"],
            wave_height_m=1.2,
            water_temp_c=21.0,
            image_url="https://images.unsplash.com/photo-1500375592092-40eb2168fd21",
            summary="Sydney staple with multiple peaks, surf history, and easy urban surf-travel storytelling.",
        ),
        Spot(
            id="spot_byron",
            name="The Pass",
            country="Australia",
            region="New South Wales",
            area="Byron Bay",
            latitude=-28.6326,
            longitude=153.6360,
            difficulty="beginner",
            best_months=["Mar", "Apr", "May", "Jun", "Jul"],
            wave_height_m=1.3,
            water_temp_c=23.0,
            image_url="https://images.unsplash.com/photo-1507525428034-b723cf961d3e",
            summary="Long cruisy right with a huge learner and longboard following in one of Australia's most famous towns.",
        ),
    ]
    forecasts = [
        forecast
        for spot in spots
        for forecast in build_estimated_forecasts(spot, today)
    ]
    trips = [
        Trip(
            id="trip_bali_july",
            user_id=user.id,
            title="Dry Season Surf Sprint",
            destination="Bali",
            start_date=today + timedelta(days=21),
            end_date=today + timedelta(days=29),
            travelers=2,
            notes="Stay near Uluwatu, scooter rental, dawn sessions first.",
            budget_usd=1800,
        )
    ]
    alerts = [
        Alert(
            id="alert_uluwatu",
            user_id=user.id,
            spot_id="spot_uluwatu",
            min_wave_height_m=1.5,
            max_wind_kts=14,
            enabled=True,
            next_check_at=datetime.now(timezone.utc) + timedelta(hours=6),
        )
    ]
    friends = [
        FriendProfile(
            id="friend_lina",
            display_name="Lina Reef",
            home_region="Canggu",
            avatar_emoji="L",
            vibe="Longboard mornings, coffee after.",
        ),
        FriendProfile(
            id="friend_ari",
            display_name="Ari Dawn",
            home_region="Uluwatu",
            avatar_emoji="A",
            vibe="Intermediate, early sessions, shares rides.",
        ),
        FriendProfile(
            id="friend_jo",
            display_name="Jo Tide",
            home_region="Siargao",
            avatar_emoji="J",
            vibe="Looking for reef buddies and cheap eats.",
        ),
    ]
    posts = [
        SocialPost(
            id="post_uluwatu_dawn",
            user_id=user.id,
            author_name=user.display_name,
            spot_id="spot_uluwatu_peak",
            post_type="general",
            visibility="public",
            body="Thinking dawn patrol at Uluwatu tomorrow if the wind stays light. Anyone keen?",
            media=[],
            meetup_date=today + timedelta(days=1),
            created_at=datetime.now(timezone.utc) - timedelta(hours=2),
        ),
        SocialPost(
            id="post_balangan_friends",
            user_id="friend_ari",
            author_name="Ari Dawn",
            spot_id="spot_balangan",
            post_type="general",
            visibility="friends",
            body="Looking for someone to split a scooter ride to Balangan this week.",
            media=[],
            meetup_date=today + timedelta(days=3),
            created_at=datetime.now(timezone.utc) - timedelta(hours=7),
        ),
    ]
    plans = [
        BillingPlan(
            id="free",
            name="Free",
            price_usd_monthly=0,
            features=["Spot explorer", "3 saved alerts", "Ad-supported home feed"],
        ),
        BillingPlan(
            id="premium",
            name="Premium",
            price_usd_monthly=7.99,
            features=["Unlimited alerts", "Trip planning", "Offline favorites", "Ad-light experience"],
        ),
    ]
    ads = [
        AdCard(
            id="ad_boardbag",
            title="Boardbag sale for island hoppers",
            partner="Saltline Gear",
            cta="Shop travel bags",
            image_url="https://images.unsplash.com/photo-1517836357463-d25dfeac3438",
            placement="home_feed",
        ),
        AdCard(
            id="ad_resort",
            title="7-night surf camp escape",
            partner="Blue Horizon",
            cta="See package",
            image_url="https://images.unsplash.com/photo-1500534314209-a25ddb2bd429",
            placement="trip_planner",
        ),
    ]
    return {
        "user": user,
        "spots": spots,
        "forecasts": forecasts,
        "trips": trips,
        "alerts": alerts,
        "plans": plans,
        "ads": ads,
        "friends": friends,
        "posts": posts,
    }


def build_estimated_forecasts(
    spot: Spot,
    start_day: date,
    days: int = 5,
) -> list[ForecastEntry]:
    wave_min_m, wave_max_m = _estimated_wave_band(spot.difficulty)
    wind_min_kts, wind_max_kts = _estimated_wind_band(spot.difficulty)
    quality = _estimated_quality(spot.difficulty)
    note = "Estimated surf band based on the spot profile while live marine data is unavailable."

    return [
        ForecastEntry(
            id=f"est_{spot.id}_{offset + 1}",
            spot_id=spot.id,
            day=start_day + timedelta(days=offset),
            wave_height_min_m=wave_min_m,
            wave_height_max_m=wave_max_m,
            wind_kts_min=wind_min_kts,
            wind_kts_max=wind_max_kts,
            quality=quality,
            source="estimated",
            confidence="estimated",
            confidence_note=note,
        )
        for offset in range(days)
    ]


def _estimated_wave_band(
    difficulty: Literal["beginner", "intermediate", "advanced"],
) -> tuple[float, float]:
    bands = {
        "beginner": (0.3, 0.8),
        "intermediate": (0.8, 1.6),
        "advanced": (1.6, 2.8),
    }
    return bands[difficulty]


def _estimated_wind_band(
    difficulty: Literal["beginner", "intermediate", "advanced"],
) -> tuple[int, int]:
    bands = {
        "beginner": (6, 14),
        "intermediate": (8, 18),
        "advanced": (10, 22),
    }
    return bands[difficulty]


def _estimated_quality(
    difficulty: Literal["beginner", "intermediate", "advanced"],
) -> Literal["fair", "good"]:
    quality = {
        "beginner": "fair",
        "intermediate": "good",
        "advanced": "good",
    }
    return quality[difficulty]
