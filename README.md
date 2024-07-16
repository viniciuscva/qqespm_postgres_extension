# QQESPM PostgreSQL Extension 

The QQESPM (Quantitative and Qualitative Efficient Spatial Pattern Matching) is a spatio-textual search solution caplable of efficiently addressing searches for geo-textual objects (e.g., Points of Interest (POIs)) based on keywords, distance, topological and exclusion restrictions, within a database of spatio-textual objects.

## Installation 

Clone the repository

    git clone git@github.com:viniciuscva/qqespm_postgres_extension.git

Access the repository folder

    cd qqespm_extension/

Copy the two necessary files to the appropriate `extension` PostgreSQL's folder on your machine. For example:

    sudo cp qqespm--1.0.sql qqespm.control /usr/share/postgresql/16/extension

Now, create a local PostgreSQL database. For example:

    CREATE DATABASE qqespm_db

## Example Usage

Create a table of geo-textual objects such as POIs (for example, using OpenStreetMap data). The table should contain the columns geometry and centroid, storing the bounding polygons and centroids of each geo-textual object. Also, the current code provided in the file `qqespm--1.0.sql` expects, as default, that a `osm_id` column in the table will exist, storing unique IDs for the geo-textual objects represented by the table's rows. 
To easily get started with this step you can simply create a sample dataset with POIs data from London, gathered and edited from OpenStreetMap. (The boundaries of the objects were augmented to create more intersections). To start this demo dataset, follow the instructions/commands described in the file `qqespm_extension_initial_config.sql` within your created database.

After that, run the following command when connected to your created database:

    CREATE EXTENSION qqespm

Now the QQESPM extension is installed. The creation of this extension defines several PLPGSQL functions that are necessary to handle QQ-SPM queries in the database.
A sample QQ-SPM query is as follows:

    SELECT * FROM match_spatial_pattern(
        array[
	    	distance_constraint('school', 'pharmacy', 10, 10000, true, false) 
	    ], 
	    'pois',
	    array['school', 'pharmacy']
    );

This sample query will return instances of `school` and `pharmacy` that are located between 10 and 10000 meters close, yielding only schools that do not contain a pharmacy closer than 10 meters. The search will the performed in the indicated `'pois'` table, and the output groups of objects will be in the order `school, pharmacy`, as determined by the third function parameter.
An explanation for the useful functions in this extension is given as documentation in the file `qqespm--1.0.sql`.

## License

[QQESPM PostgreSQL's extension](https://github.com/viniciuscva/qqespm_postgres_extension/) © 2024 by [Carlos Vinicius A. M. Pontes](https://www.linkedin.com/in/vinicius-alves-mm/) is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/?ref=chooser-v1).
