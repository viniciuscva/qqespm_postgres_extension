create extension if not exists hstore;
create extension if not exists postgis;

CREATE TABLE london_pois_demo(
    osm_id bigint,
    name varchar(200),
    amenity varchar(50),
    shop varchar(50),
    tourism varchar(50),
    landuse varchar(50),
    leisure varchar(50),
    building varchar(50),
    geometry geometry,
    centroid geometry
);
COPY london_pois_demo FROM 'london_sample_pois_osm_data/london_osm_pois_demo.csv' DELIMITERS ',' CSV HEADER;


ALTER TABLE pois ADD COLUMN id SERIAL PRIMARY KEY;
CREATE INDEX spatial_ind_london_osm_pois_demo_geom ON london_osm_pois_demo USING GIST ( geometry );
CREATE INDEX spatial_sp_ind_london_osm_pois_demo_geom ON london_osm_pois_demo USING SPGIST ( geometry );
CREATE INDEX spatial_ind_london_osm_pois_demo_centroid ON london_osm_pois_demo USING GIST ( centroid );
CREATE INDEX spatial_sp_ind_london_osm_pois_demo_centroid ON london_osm_pois_demo USING SPGIST ( centroid );

-- Set a statement timeout if you want to test heavy queries. For example, 30 minutes:
-- SET statement_timeout TO 1800000 ;
