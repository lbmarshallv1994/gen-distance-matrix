This PERL program uses the **Bing Maps API** to create a distance matrix of your org units based on the longitude and latitude in the org unit addresses. The distance matrix will give you the distance of the shortest route between any two org units.

## Dependencies

This program uses the following PERL dependencies:
* Parse::CSV
* List::Util
* List::MoreUtils
* Config::Tiny
* Data::Dumper
* DBI
* DateTime  
* Time::Piece
* Spreadsheet::Read
* LWP::Simple
* Geo::Coder::Bing
* JSON::Parse
* Excel::Writer::XLSX
* Net::OpenSSH
* JSON

These should all be on CPAN.

## Installation

1. Create your account with Microsoft and apply for a key with the Bing Maps API, it's free to use with limitations.
2. Set up your API connection in **config.ini** using the provided example file.
    * enter the Key Microsoft gives you at **key=**
    * The program breaks down the origin coordinates into smaller chunks to send off to the API because there is a limit on the maximum product. For my key this limit was 2500. So if you have 100 addresses total and a limit of 2500 product, instead of a 100x100 matrix (product 10,000) would need to be broken down into 4 25x100 matricies. This will chew through your allowed transactions, so keep that in mind.
3. Install the dependencies using CPAN.
    ```
    cpan -i Parse::CSV
    ```
## Usage

```
perl geospatial_differentializer.pl
```
