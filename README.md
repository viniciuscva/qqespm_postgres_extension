# QQESPM PostgreSQL Extension 


git clone git@github.com:viniciuscva/qqespm_postgres_extension.git

cd qqespm_extension/

sudo cp qqespm--1.0.sql qqespm.control /usr/share/postgresql/16/extension

Now, create a local PostgreSQL database and run the commands described in file qqespm_extension_initial_config.sql.

After that, run the following command when connected to your created database:

CREATE EXTENSION qqespm

Now the QQESPM extension is installed. This command creates several PLPGSQL functions necessary to handle QQ-SPM queries in the database.
A sample QQ-SPM query is as follows:

SELECT * FROM match_spatial_pattern(
    array[
		distance_constraint('school', 'pharmacy', 10, 10000, true, false) 
	], 
	'pois',
	array['school', 'pharmacy']
);

This sample query will return instances of school and pharmacy that are located between 10 and 10000 meters close, yielding only schools that do not contain a pharmacy closer than 10 meters.
